---
layout: post
title: "A metadata tree that grows with the change"
chapter: 10
period: "13 May 2026"
dek: "Iceberg v4 replaces the manifest list with a root manifest. It sounds like a file rename. It changes what a small commit costs."
---

This year I moved down a layer. After two years inside query engines, deciding what not to read, I started working on the table format underneath them: [Apache Iceberg](https://iceberg.apache.org/), and specifically the metadata changes going into version 4 of its spec.

This chapter is about the biggest of those changes, the **adaptive metadata tree**. It's an explainer of the public spec plus what I learned implementing it. I'll only describe what's in the spec and upstream proposals, not anything specific to how we use it.

## How an Iceberg commit works today

An Iceberg table is a tree of files. At the top is a table metadata file. It points to the current snapshot, and the snapshot points to a **manifest list**. The manifest list points to **manifests**, and each manifest lists data files along with their partition values and column statistics.

A commit writes new files bottom-up and then atomically swaps the table's pointer from the old metadata file to the new one. If someone else committed first, you rebase and try again. That's the optimistic concurrency model, and it's the reason Iceberg works on plain object storage without a lock server.

Now look at what a small append writes in versions 1 to 3:

1. the new data file,
2. a new manifest listing it (the "fast append"),
3. a **new manifest list** containing an entry for *every* manifest in the snapshot,
4. a new table metadata file.

Step 3 is the problem. The manifest list is rewritten on every commit, and its size grows with the number of manifests in the table, not with the size of the change. A writer that appends small batches often keeps adding manifests, so each commit rewrites a slightly bigger list than the last. Eventually someone has to run manifest rewriting in the background to merge them, which is another writer competing for the same commit pointer.

The cost of a commit ends up tracking the size of the table's metadata rather than the size of the change. For tables that are mostly read and occasionally written that's fine. For tables that take a steady stream of small appends it becomes the bottleneck.

## The root manifest

Version 4 removes the manifest list. Each snapshot points to a single **root manifest**, which is itself a manifest, and it can hold three kinds of entries:

- data files, directly,
- **leaf manifests**, which hold data files,
- older v1–v3 manifests, so existing tables can be upgraded without rewriting history.

Both root and leaf manifests are Parquet files in v4, not Avro. That gets its own chapter, because it matters as much as the tree.

{% include diagrams/metadata-tree.svg %}

The important part is the first kind of entry. A small append no longer needs its own manifest *and* a rewritten list. Its data files can go straight into the root. The commit writes the data file, one new root manifest, and the table metadata. Later, when the root has accumulated enough loose files, a writer can move them down into a leaf manifest, and the root goes back to holding a short list of pointers.

That's what "adaptive" means here. The tree is shallow where things change often and deeper where they don't. The spec defines the structure. It deliberately doesn't say when to push files down, how big a root should get, or how leaves should be grouped. Those are implementation choices, and they're where most of the engineering is.

## Removing an entry without rewriting a leaf

The second piece is about deletes and compaction. In v1–v3, if compaction replaces ten small files with one big one, every manifest that listed those ten files has to be rewritten without them.

Version 4 adds **manifest deletion vectors**. The root manifest's entry for a leaf can carry a bitmap of positions in that leaf that are no longer live. Removing a file from a leaf means setting a bit on the root entry, while the leaf itself stays untouched. The bitmaps use [Mumbling](https://iceberg.apache.org/mumbling-spec/), a compact bitmap encoding the Iceberg project specifies for this, and each one records which snapshot last changed it.

The same idea shows up one level down. A data file's own deletion vector, the bitmap of deleted rows inside it, now lives in the same manifest entry as the data file. Readers no longer have to plan in two phases, finding data files first and then doing a second lookup to match delete files to them. The deletes sit in the same entry as the file they apply to, so planning reads one thing instead of joining two.

## Smaller changes that matter to implementers

A few other v4 rules changed how I wrote code more than I expected:

- **Strictly increasing snapshot timestamps.** On a v4 table, a snapshot's timestamp must be strictly greater than its parent's on the same branch. Two fast writers on machines with slightly different clocks can break that, so the commit path has to compare against the parent and bump the timestamp past it when the local clock hasn't moved far enough, rather than trusting the machine's time.
- **Relative paths.** Metadata can store file locations relative to the table location, which makes copying or moving a table much less painful.
- **No new equality deletes.** Writers can't produce new equality delete files in v4. Existing ones stay readable.
- **Sequence numbers are inherited.** New entries are written without a sequence number, and readers fill it in from the parent. That's what lets a writer write a leaf manifest once and reuse it across commit retries. Only the root has to be rewritten when the commit is retried.

## What I learned implementing it

**The spec gives you the shape, not the policy.** Every interesting decision is about *when*: when to push loose files into leaves, when a leaf is too big, when to fold manifest deletion vectors back into a rewritten leaf. Get the policy wrong and you can rebuild the very problem v4 set out to fix, a root that grows with the table.

**The retry path is the real commit path.** Under optimistic concurrency, retries aren't a corner case. With several writers they're routine. Most of the bugs I found weren't in the happy path. They were in what a retry reuses, what it recomputes, and what it must validate again against the new base snapshot.

**Write down the invariants and test them on purpose.** The spec says each file must appear in at most one live entry across the snapshot, and it explicitly doesn't require writers to check that at commit time. That's a reasonable spec decision, and it means the checking is on you. Randomized sequences of appends, compactions and retries, checked against a written-down list of invariants, are the cheapest way I know to find the bugs that hide in retries.

The next chapter goes into the other half of v4: what changes when manifests themselves become Parquet files, and why that made commits cheaper too.
