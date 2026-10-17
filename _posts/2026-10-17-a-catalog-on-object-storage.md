---
layout: post
title: "An Iceberg catalog with no database: Lakekeeper on SlateDB"
tags: [iceberg, lakehouse, storage]
when: 2026-06-17
period: "17 June 2026"
dek: "I wrote a backend that keeps an Iceberg REST catalog's state in SlateDB, a key-value store that lives entirely in object storage. It worked, and it kept the catalog's state out of a database. This note is mostly about what it cost: the guarantees I rebuilt, the ones I didn't, and what I'd do differently."
---

An Iceberg table is files in object storage plus one pointer: the location of the current metadata file. Everything else in a lakehouse can be scaled, cached or thrown away and rebuilt. That pointer can't. Every writer swaps it with a compare-and-swap, and the catalog is the thing that owns the swap.

[Lakekeeper](https://github.com/lakekeeper/lakekeeper) is an open-source Iceberg REST catalog written in Rust. The server is stateless and keeps its state in Postgres. That's a sensible default, and for most people the right one. But it does mean that a system whose data lives entirely in object storage still needs a database next to it, with its own backups, upgrades, failover and on-call.

[SlateDB](https://slatedb.io) is an embedded key-value store that writes everything, its write-ahead log included, to object storage. No disks to manage, no replicas to run. So the obvious question: can the catalog live in the same bucket as the tables it describes?

I built a SlateDB backend for Lakekeeper to find out. It runs, it passes about 170 tests, and I learnt more from its limitations than from the parts that worked.

## Why bother

The motivation wasn't performance. Postgres is faster at almost everything a catalog does. It was operational:

- **One durable system, not two.** If the tables and the catalog live in the same object store, durability, replication and backup are one problem, solved by the cloud provider.
- **Nothing stateful to run.** The catalog becomes a process that can be killed and restarted anywhere, as long as only one copy writes at a time.
- **Cost proportional to use.** A catalog that serves a few commits a minute doesn't need a database instance sized for peak.

It's not an unusual idea. Someone opened a [Lakekeeper issue proposing exactly this](https://github.com/lakekeeper/lakekeeper/issues/2079) in October 2026. The maintainers' answer is worth quoting in spirit: they don't have the capacity to support another backend upstream, because maintaining one is a lot of continuous effort. Having done it, I agree. That sentence is the most accurate summary of this note.

## What a backend has to implement

Lakekeeper's backend is chosen at compile time: you hand a storage type to the server. The contract is a set of Rust traits, and it's much bigger than "store table metadata":

- a **transaction** trait: begin a read or write transaction, commit, roll back;
- a **catalog store** trait with close to a hundred async methods: projects, warehouses, namespaces, tables, views, generic tables, roles, users, role memberships (transitive, paginated), endpoint statistics, a **task queue**, and idempotency keys;
- a **secret store** for storage credentials.

The Postgres backend leans on SQL for almost all of it, and each of those SQL features became something I had to rebuild by hand.

| Postgres gives you | On a key-value store, I had to build |
|---|---|
| A table commit as one `UPDATE … WHERE metadata_location = old` | A read, a compare, and a write |
| `UNIQUE` constraints, case-insensitive | Name-index keys, checked before insert |
| Secondary indexes | About twenty hand-maintained index key families |
| `ORDER BY … LIMIT` with a cursor | Prefix scans plus pagination tokens |
| Recursive queries over role membership | Graph walks in memory |
| `FOR UPDATE SKIP LOCKED` for the task queue | A scan for the first scheduled task |
| Trigram search | Substring match over a scan |
| `ALTER TABLE` and migrations | Versioned rewrite functions run at startup |

## How it's built

**Keys are paths.** Every record has a primary key (`table/{id}`, `ns/{id}`, `warehouse/{id}`) and one or more index keys that point at it (`table_by_name/{warehouse}/{namespace}/{name}`, `table_by_metadata_loc/{location}`, and so on). Names come from users, so every user-supplied segment is percent-encoded before it goes into a key. My first encoding replaced a few characters and could make two different names collide. Fixing that needed a migration that rebuilt every index. In a key-value store, the key encoding is the schema, and I learnt that the expensive way.

**Records are JSON.** Postgres splits Iceberg table metadata across about fifteen normalised tables. I stored the whole metadata document in the table's record. Simpler, and fine for a catalog that mostly reads and replaces the whole thing.

**A transaction is a buffer.** Each request collects its puts and deletes and writes them at commit as one atomic batch. That's what keeps a record and its indexes from ever being half-written. Reads inside the transaction merge the pending buffer over the database, so a request sees its own writes. The first version didn't, and a request that created something and then looked it up couldn't find it. Tests caught that in the first week.

**Migrations are code.** A schema version key, and an ordered list of functions that rewrite keys and values from one version to the next, run by the writer at startup. There's no `ALTER TABLE` in a key-value store.

## The limitations

This is the part that matters, and the reason I'd tell anyone to think hard before doing the same.

**One writer, so no high availability.** SlateDB is [designed for a single writer](https://slatedb.io/docs/get-started/introduction/) and fences out old ones with an epoch in its manifest. That's a good design, and it's what keeps two writers from corrupting each other. But it means the catalog has exactly one process that can commit. Restart it and every table in the lakehouse is read-only until it's back. Start a second copy and it fences the first instead of sharing the load. Lakekeeper on Postgres is stateless and scales horizontally. On SlateDB, it isn't and doesn't. SlateDB supports readers on other nodes, and serving catalog reads from them is the obvious next step. I didn't build it.

**Every commit waits for object storage.** A commit is only durable once the write-ahead log has reached object storage. That's a flush interval plus a PUT, so tens to hundreds of milliseconds, where Postgres takes a few. SlateDB is upfront about this: it's [meant for workloads that tolerate 50 to 100 ms writes](https://slatedb.io/docs/get-started/introduction/). For a catalog that's acceptable. For a catalog under a streaming writer committing to hundreds of tables, it's the number to watch.

**My compare-and-swap isn't atomic.** This is the honest one. Postgres does the commit in one statement: update the pointer only if it still points where the client thinks. My backend reads the record, compares, then writes. The server is the only writer, so a lock around that path would have been enough. I didn't add one, and with many concurrent requests in one process, nothing stops two of them passing the check before either writes. The same window exists for name uniqueness and for claiming a task from the queue. And when my backend did detect a conflict, it reported a server error rather than Iceberg's 409 conflict, which a client reads as "I don't know if my commit happened" rather than "retry".

What makes this worse is that it was avoidable. SlateDB has had [transactions with snapshot and serializable-snapshot isolation](https://slatedb.io/rfcs/0011-transaction/) since late 2025, with write-write conflict detection. I built on plain write batches instead, because they were simpler and I was copying the shape of the Postgres backend. A real compare-and-swap, real uniqueness and safe task claiming are all one transaction away. If I started again, that's the first thing I'd change.

**The task queue was the sharpest edge.** Lakekeeper schedules background work, like cleaning up dropped tables, through its task queue, and some of those tasks reschedule themselves. My first port dropped the "not before this time" condition when picking tasks. Self-rescheduling tasks ran as fast as the loop could pick them, every write went to the log, the log grew, and replaying it on restart got slow enough that the process failed its health checks. A one-line filter in SQL became an outage-shaped bug in a key-value port. The queue also ignores heartbeat timeouts, so a task held by a crashed worker is never picked up again.

**Lists and searches don't scale.** Pagination scans the whole prefix and skips to the cursor, so every page costs as much as the whole list. Search is substring matching over a scan. Role inheritance is walked in memory. All of it is fine for hundreds of tables. None of it is fine for millions.

**Some things are missing.** Endpoint and warehouse statistics return nothing. Secrets are stored without encryption, which rules it out for anyone who keeps real credentials in the catalog. Authorisation through OpenFGA still needs its own database, so "no database" only holds if you don't use it.

**Operations get harder.** There's no SQL console. Debugging means reading keys by hand. Backing up by copying the prefix isn't safe while compaction is rewriting files underneath it. SlateDB has checkpoints for exactly this, but I never wired them into a backup. When something goes wrong, the answer is often "look at the log files in the bucket", which is a sentence nobody wants in a runbook.

**The interface moves.** Lakekeeper changed the backend traits a week after I finished, and the backend didn't compile until I caught up. Every upstream release is a small porting job. That's the maintainers' point, felt from the other side.

## What about FoundationDB?

The other backend people reach for in this conversation is [FoundationDB](https://apple.github.io/foundationdb/), and it's worth being precise about the difference, because it's the whole design space in one line. FoundationDB is a distributed key-value store with strictly serializable transactions across many writers. Putting a catalog on it gives you everything Postgres gives you except SQL: real compare-and-swap, real uniqueness, many active catalog servers, no single writer to restart. What it doesn't give you is "no stateful system to run". FoundationDB is a cluster with its own disks, coordinators and operational folklore. It's arguably harder to run than Postgres.

So the three options sit on one axis:

- **Postgres:** transactions and SQL, a database to operate.
- **FoundationDB:** transactions across many writers, a harder cluster to operate.
- **SlateDB:** nothing to operate but a bucket, at the price of a single writer and object-storage latency.

None of them is wrong. They trade operational weight for concurrency, and the right one depends on how many writers you have and how much infrastructure you're willing to own.

## What I'd tell someone starting

- **Count the contract first.** "Store the catalog in a key-value store" sounds like a table and an index. It's a hundred methods, a task queue, authorisation data and secrets.
- **Use the store's transactions.** Every hand-rolled check-then-write in this backend is a race that SlateDB's transactions would have closed.
- **Map conflicts to conflicts.** A 409 makes a client retry. Anything else makes it wonder whether its data is there.
- **Port the `WHERE` clauses, not just the tables.** The worst bug here was a time condition that didn't make the trip from SQL.
- **Decide about availability up front.** A single writer is a feature for correctness and a bug for uptime. Know which one your users will notice.
