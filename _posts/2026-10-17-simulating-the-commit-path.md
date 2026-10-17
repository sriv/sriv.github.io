---
layout: post
title: "Simulating the commit path: deterministic tests for streaming writes to Iceberg"
tags: [testing, iceberg, distributed]
when: 2026-08-13
period: "13 August 2026"
dek: "A streaming writer commits to an Iceberg table every few seconds, retries on conflict, and shares the table with compaction and garbage collection. I borrowed SlateDB's approach to deterministic simulation to test it. It caught less than I hoped, and taught me more."
---

A streaming writer is a very persistent client of a table format. It lands a few files, commits, and does it again a few seconds later, forever. Around it, other processes rewrite the same table: compaction merges small files, garbage collection deletes files nothing points to, snapshot expiry trims history. Every one of them commits through the same optimistic protocol: read the current metadata, write new metadata, swap a pointer, and retry from the top if someone else got there first.

Each of those steps is simple. The bugs live in the interleavings: a retry that rebuilds its change from stale state, a garbage collector that sees a file a moment before the commit that references it lands, a clock that disagrees with another clock. They show up in production as a handful of rows read twice, or a file deleted that a snapshot still needs. They almost never show up in a unit test, because a unit test runs one interleaving, the friendly one.

This summer I built a deterministic simulation harness for that commit path. This note is about how it works, what it found, and, more usefully, what it didn't.

## The idea, borrowed

The approach isn't mine. FoundationDB made deterministic simulation famous, TigerBeetle and others built on it, and tools like [madsim](https://github.com/madsim-rs/madsim) and [Antithesis](https://antithesis.com/docs/resources/deterministic_simulation_testing/) generalised it. The version I learnt the most from was [SlateDB's `slatedb-dst`](https://github.com/slatedb/slatedb/tree/main/slatedb-dst), because it solves almost the same problem: a storage engine whose only durable state lives in object storage.

Its shape is worth copying:

- **One seed decides everything.** A root random generator derives the seeds for the runtime, the clock and every actor, so a failing run can be replayed exactly from one number.
- **The world is simulated.** A mock clock instead of the system clock, a deterministic filesystem standing in for object storage, and a single-threaded runtime so scheduling is reproducible.
- **Faults are part of the world.** An object store wrapper injects latency, dropped connections and errors with seeded probabilities.
- **Invariants, not examples.** The flagship test is a bank: actors transfer money between accounts while an auditor checks that the total never changes, through every kind of reader.
- **Determinism is itself tested.** The same seed is run twice and the runs must agree. Otherwise the harness is quietly testing something else.
- **It runs all the time.** SlateDB runs its simulations in CI every hour.

{% include diagrams/dst-loop.svg %}

## Two tiers

I ended up with two kinds of simulation, and the distinction turned out to matter more than anything else.

### Models of the protocol

The first tier doesn't run the real code at all. It's a few hundred lines of plain Rust that model one piece of the commit protocol: a table as a set of files, a catalog as a pointer, writers and collectors as actors taking seeded steps. No dependencies, a tiny seeded generator, and a function that runs a schedule and returns the first invariant it breaks.

Each model comes as a pair:

- a **naive** version of the algorithm, which the harness must catch breaking the invariant on many seeds, and
- a **safe** version, which must hold the invariant on every seed.

The pairing keeps the harness honest. If the naive version stops failing, the simulation has lost its teeth, not found a fix.

The models covered the commit races I cared about:

- **Commit against garbage collection.** Invariant: every file reachable from the table exists in storage. The naive collector deletes anything currently unreachable, which includes files written by a commit that hasn't landed yet. The safe one waits out a grace period.
- **Optimistic retry of a rewrite.** Invariant: the table's content never changes across a rewrite, and the files stay a partition of it, with no row in two files. The naive retry reuses the list of files it decided to remove before the conflict.
- **At-least-once delivery.** A consumer that deduplicates by message id turns at-least-once into exactly-once. One that doesn't, doesn't.
- **Clock skew.** A grace period measured in wall-clock time is defeated by a collector whose clock runs ahead. A guard based on the catalog's own sequence numbers isn't, because it never asks anyone what time it is.

That last one is my favourite result of the whole exercise. It turned a vague worry ("what if clocks drift?") into a precise rule: never let a correctness decision depend on two machines agreeing about time.

I want to be honest about what this tier is, though. Every one of those models reproduces a bug we'd already had or already feared. They're **executable specifications of known failures**. That's valuable: the rule is now written down in a form that fails loudly, and the next person to touch the protocol inherits it. But it isn't discovery.

### The real code, under faults

The second tier runs the real table library: the real transaction and its retry loop, the real manifest writer, the real scan planner, in-process against an in-memory catalog and file system. Seeded schedules mix appends, rewrites and expiries, and after every commit the test checks the table against an **oracle**, a plain set of the files that should be live:

- nothing lost and nothing duplicated: the scan returns exactly the oracle's files,
- a failed commit leaves the table unchanged,
- the reachable set is exactly the set of successful commits, with no phantoms,
- after expiring every older snapshot, the current one is still fully readable.

Faults come from two wrappers. One fails the catalog's register step, which models a crash after the files are written but before the commit is recorded. The other sits under the file system and fails reads, writes and deletes, adds latency, or partitions the network until healed.

My favourite invariant in this tier is a small one: **a read fault must surface as an error, never as fewer rows.** A scan that swallows a failed read and returns a short result is the worst kind of bug in an analytical engine, because nothing about the answer looks wrong.

## What it caught

Less than I'd hoped. And the best catch was one I ignored.

**The signal I misread.** One of the first real-code tests appended three files in one commit, replaced two of them with a merged file, and expected the merged file plus the untouched one. On one format version it failed: the replaced files stayed live. I'd only just built the harness, the failure involved a code path I was less sure the test set up correctly, and I concluded the harness was wrong. I marked the test ignored and moved on.

Two months later the same bug turned up the expensive way. When a rewrite touched a manifest that mixed files being replaced with files being kept, it wrote every entry back as newly *added*, including the ones that should have been marked *deleted*. The replaced files stayed live next to their replacement, so every merged row was read twice. The snapshot summary still reported the deletes, which made it look fine to anything that only read the summary. Looking back, the regression test written for the fix has almost exactly the shape of the test I'd ignored in August. To be sure, I ran the August test, unchanged, against the code from just before the fix. It fails exactly as it did then, with the two replaced files still live next to their replacement. On the fixed code, it passes.

The harness did its job. I didn't do mine. The lesson I took is now a rule: **a red simulation test is a bug until proven otherwise**, and "the harness is probably wrong" needs the same evidence as "the code is wrong".

**A safety switch wired to nothing.** Writing a test for conflicting rewrites, I found a flag meant to disable retries for exactly that case. The retry logic read it. Nothing ever set it. It had been wired up after an earlier incident, then unwired when a better fix made retries safe, and the flag was left behind looking like protection. It wasn't a live bug, but it's the kind of thing only a test that tries to use the switch will find.

**The harness that tested nothing.** After a dependency upgrade, the in-memory file system stopped going through the I/O layer the fault injector was attached to. Every fault test kept passing, because no fault ever reached the code under test. The fix was to wrap the storage at the level the commit and scan paths actually call, and to make sure the wrapper hands back wrapped readers and writers rather than the inner ones. That's the reason for SlateDB's determinism test, and I'd now add a cousin to every harness: **a test that proves the faults are landing**, by checking that the naive version still fails.

## What it doesn't do

This is the part I'd want to read if someone else had written this note.

- **It's barely concurrent.** The real-code tier has no simulated scheduler. Races are staged by hand: two transactions from the same starting point. The interleavings it explores are the ones I thought of.
- **Time isn't simulated in the real code.** The library still asks the system clock. Clock skew is tested with synthetic timestamps, which is weaker than owning the clock.
- **Too few seeds, too rarely.** A dozen seeds per test, run with the normal test suite. No soak runs, no hourly job, no way to throw a million seeds at it overnight. SlateDB does all three.
- **The oracle is too coarse.** It tracks which files should be live, not what rows they hold, and the schedules for one format version never included rewrites at all. That gap is exactly where the missed bug lived.
- **No real catalog, no real crash.** The catalog is in memory, so there's no network between the writer and its commit. And the streaming writer itself never crashes and restarts inside the simulation, which is where exactly-once really gets tested.

Most of that list is one piece of work: threading a clock and a storage interface through the writer and the catalog client, so the simulation can own both. That's the line between "tests with seeds" and a simulation, and SlateDB is on the right side of it.

## What I'd do again

- **Pair every model with a naive version that must fail.** It's the cheapest way to know the harness can still see.
- **Make "never fewer rows" an invariant.** Silent short reads are the bug analytical systems can't afford.
- **Prefer logical clocks for correctness.** Anything that compares wall-clock times across machines will eventually be wrong.
- **Treat red as real.** The most valuable output of a simulation is a failure you don't yet understand. It deserves more time, not less.
- **Run it constantly.** A simulation that runs a dozen seeds once per pull request is a unit test with extra steps. The value is in the volume.
