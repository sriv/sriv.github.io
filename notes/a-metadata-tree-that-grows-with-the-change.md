# A metadata tree that grows with the change

By Srikanth Venugopalan, 5 June 2026. Topics: iceberg.
Canonical: https://sriv.github.io/notes/a-metadata-tree-that-grows-with-the-change/

> The draft Iceberg v4 spec replaces the manifest list with a root manifest. It sounds like a file rename. It changes what a small commit costs.

[Manifests are data too](https://sriv.github.io/notes/manifests-are-data-too/) was about manifests becoming Parquet files. This one is about the bigger structural change in the draft version 4 of the Iceberg spec, the **adaptive metadata tree**. It's an explainer of the public spec plus what I learned implementing it. I'll only describe what's in the spec and upstream proposals, not anything specific to how we use it.

## How an Iceberg commit works today

An Iceberg table is a tree of files. At the top is a table metadata file. It points to the current snapshot, and the snapshot points to a **manifest list**. The manifest list points to **manifests**, and each manifest lists data files along with their partition values and column statistics.

A commit writes new files bottom-up and then atomically swaps the table's pointer from the old metadata file to the new one. If someone else committed first, you rebase and try again. That's the optimistic concurrency model, and it's the reason Iceberg works on plain object storage without table locks: the only coordination is one atomic swap in the catalog.

Now look at what a small append writes in versions 1 to 3:

1. the new data file,
2. a new manifest listing it (this is what a fast append does),
3. a **new manifest list** containing an entry for *every* manifest in the snapshot,
4. a new table metadata file.

Step 3 is the problem. The manifest list is rewritten on every commit, and its size grows with the number of manifests in the table, not with the size of the change. A writer that frequently appends small batches keeps adding manifests, so each commit rewrites a slightly bigger list than the last. Eventually the manifests have to be merged, either inline during some commits, which makes those commits bigger, or by a background rewrite, which is another writer competing for the same commit pointer.

The cost of a commit ends up tracking the size of the table's metadata rather than the size of the change. For tables that are mostly read and occasionally written that's fine. For tables that take a steady stream of small appends it becomes the bottleneck.

## The root manifest

Version 4 removes the manifest list. Each snapshot points to a single **root manifest**, which is itself a manifest, and it can hold three kinds of entries:

- data files, directly,
- **leaf manifests**, which hold data files,
- older v1–v3 manifests, so existing tables can be upgraded without rewriting history.

Root and leaf manifests written in v4 are Parquet files, not Avro, which was the subject of the previous post.

[Diagram: In Iceberg v1 to v3, table metadata points to a manifest list that is rewritten on every commit and has one entry per manifest, so a small append writes a new manifest and a growing list. In v4, table metadata points to a Parquet root manifest that holds leaf manifests and can hold data files directly; small appends go straight into the root, and a deletion bitmap on the root's entry marks files in a leaf as removed without rewriting the leaf.]

*The manifest list grows with the table. The root manifest grows with the change, as long as someone keeps it small.*

The important part is the first kind of entry. A small append no longer needs its own manifest *and* a rewritten list. Its data files can go straight into the root. The commit writes the data file, one new root manifest, and the table metadata. Later, when the root has accumulated enough loose files, a writer can move them down into a leaf manifest, and the root goes back to holding a short list of pointers.

That's what "adaptive" means here. The tree is shallow where things change often and deeper where they don't. The spec defines the structure. It deliberately doesn't say when to push files down, how big a root should get, or how leaves should be grouped. Those are implementation choices, and they're where most of the engineering is.

## Removing an entry without rewriting a leaf

The second piece is about deletes and compaction. In v1–v3, if compaction replaces ten small files with one big one, every manifest that listed those ten files has to be rewritten without them.

Version 4 adds **manifest deletion vectors**. The root manifest's entry for a leaf can carry a bitmap of positions in that leaf that are no longer live. Removing a file from a leaf means setting bits on the root entry, while the leaf itself stays untouched. The bitmaps use [Mumbling](https://iceberg.apache.org/mumbling-spec/), a compact bitmap encoding the Iceberg project specifies for this, and the root entry records which snapshot last changed them.

The same idea shows up one level down. A data file's own deletion vector, the bitmap of deleted rows inside it, now lives in the same manifest entry as the data file. For files written under v4, readers no longer have to plan in two phases, finding data files first and then doing a second lookup to match delete files to them. The deletes sit in the same entry as the file they apply to, so planning reads one thing instead of joining two.

## Smaller changes that matter to implementers

A few other v4 rules changed how I wrote code more than I expected:

- **Strictly increasing snapshot timestamps.** On a v4 table, a snapshot's timestamp must be strictly greater than its parent's on the same branch. Two fast writers on machines with slightly different clocks can break that, so the commit path has to compare against the parent and bump the timestamp past it when the local clock hasn't moved far enough, rather than trusting the machine's time.
- **Relative paths.** Metadata can store file locations relative to the table location, which makes copying or moving a table much less painful.
- **No new equality deletes.** Writers can't produce new equality delete files in v4. Existing ones stay readable.
- **Sequence numbers are still inherited.** As in v2 and v3, files added to a new leaf manifest are written without a sequence number, and readers fill it in from the root manifest's entry for that leaf. That's what lets a writer write a leaf manifest once and reuse it across commit retries. Only the root has to be rewritten when the commit is retried.

## What I learned implementing it

**The spec gives you the shape, not the policy.** Every interesting decision is about *when*: when to push loose files into leaves, when a leaf is too big, when to fold manifest deletion vectors back into a rewritten leaf. Get the policy wrong and you can rebuild the very problem v4 set out to fix, a root that grows with the table.

**The retry path is the real commit path.** Under optimistic concurrency, retries aren't a corner case. With several writers they're routine. Most of the bugs I found weren't in the happy path. They were in what a retry reuses, what it recomputes, and what it must validate again against the new base snapshot.

**Write down the invariants and test them on purpose.** The spec says each file must appear in at most one live entry across the snapshot, and it explicitly doesn't require writers to check that at commit time. That's a reasonable spec decision, and it means the checking is on you. Randomized sequences of appends, compactions and retries, checked against a written-down list of invariants, are the cheapest way I know to find the bugs that hide in retries.
