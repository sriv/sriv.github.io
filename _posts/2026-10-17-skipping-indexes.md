---
layout: post
title: "Skipping indexes: how they work and when they pay"
chapter: 12
period: "23 August 2026"
dek: "Indexes in an analytical engine don't find rows. They rule out files. A tour of the structures that do it, where Iceberg's Puffin files fit, and what building them taught me."
---

Say "index" to someone who grew up on OLTP databases and they picture a B-tree: a structure that takes a key and walks to the row. Analytical engines over object storage mostly don't have those, and mostly don't want them. The data is immutable files, the queries touch millions of rows, and a pointer to one row isn't worth much when the unit you pay for is a request to fetch part of a file.

The indexes that matter in that world answer a different question: **which pieces of data can I prove don't contain what this query wants?** They're skipping indexes. They never say where a row is, only where it can't be. Everything in [the cheapest row is the one you never read](/notes/the-cheapest-row-is-the-one-you-never-read/) applies to them, including the one rule that matters most: an index may answer "maybe" as often as it likes, but it must never give a wrong "no".

I spent a good part of this year building a family of these indexes on Iceberg tables, from the writer that produces them to the reader that trusts them. This note is the general version: what each structure is, when it pays, where it lives, and the ways I've seen them go wrong.

## The ladder

A skipping index works at some granularity, and the granularity decides both what it saves and what it costs.

{% include diagrams/skip-ladder.svg %}

- **Partition.** Skip a whole directory of files without opening any of them. Cheapest to consult, coarsest answer.
- **File.** Skip one data file. On object storage this is the one that matters most, because a skipped file is requests you never make.
- **Row group.** Skip a chunk inside a file you've already decided to open. Saves bytes and decoding, but you've paid for the footer.
- **Page.** Skip a few kilobytes inside a column chunk. Useful on selective queries over well-sorted data.
- **Row.** Hand the scan a bitmap of the rows worth decoding. Precise, and the largest structures by far.

Every level up the ladder is cheaper to ask and less precise. The usual mistake is to build a fine-grained index when the expensive thing is coarse. If a query opens a thousand files to find matches in three, a row-level index inside each file doesn't fix it. You need something that rules out the other 997 before they're opened.

## The structures

### Min/max bounds

The oldest trick. For each column, keep the smallest and largest value in each file or row group. A predicate like `ts > '2026-08-01'` skips every chunk whose maximum is earlier.

Bounds are nearly free to compute and store, and Parquet and Iceberg both keep them already: Parquet per row group and, with the page index, per page; Iceberg per data file in its manifests.

**When they pay:** when the data is sorted or clustered on the column, so each chunk covers a narrow range. Time columns in append-only tables are the classic case.

**When they don't:** when values are spread randomly across files. If every file's range is `a` to `z`, bounds rule out nothing. That's a layout problem, not an index problem, and the fix is sorting or clustering at write time.

### Exact value sets, with a cap

For a low-cardinality column (a status, a region, a service name) you can store the actual set of distinct values in each file. Then `status = 'FAILED'` skips any file whose set doesn't contain it, and an `IN` list checks each value. Unlike bounds, this works no matter how the data is laid out.

The cap is the whole design. Above some number of distinct values the set stops being cheap, so the writer gives up and records "too many to list". That marker has to mean **maybe**, and it has to stay maybe forever after. More on that below.

**When they pay:** equality and `IN` filters on columns with tens to low thousands of distinct values per file. In practice a single well-chosen value set can account for most of the skipping on a table.

### Bloom filters

For high-cardinality columns where you look up one value at a time (IDs, keys, hashes), a value set would be as big as the column. A bloom filter answers "definitely not here" or "maybe" in a fixed number of bits.

The mechanics fit in a paragraph. Allocate *m* bits. To insert a value, hash it *k* ways and set those *k* bits. To query, check the same *k* bits: if any is zero, the value was never inserted. For a target false-positive rate *p* you need about 1.44 × log₂(1/*p*) bits per distinct value, so around 9.6 bits for 1%, with *k* ≈ 7.

The useful way to reason about a bloom filter after the fact is its **fill**: the fraction of bits set. The false-positive rate is roughly fill to the power *k*. A filter that's half full with *k* = 7 lies about 1% of the time. A filter that's 90% full lies about half the time, and at that point it's paying its storage and a read to tell you almost nothing.

**When they pay:** point lookups and small `IN` lists on high-cardinality columns. Parquet supports them per column chunk, though most writers leave them off ([bloom filters at the scan](/notes/bloom-filters-at-the-scan/) is about that).

**When they don't:** range predicates, `LIKE '%x%'`, anything that isn't equality. And columns where every file contains most values anyway.

### Inverted indexes

For text, the question is "which rows contain this token?". An inverted index answers it with two parts.

The **term dictionary** maps each distinct token to where its postings live. A good choice for an immutable file is a finite-state transducer (FST): a minimal automaton over the sorted terms that shares both prefixes and suffixes, so a dictionary of millions of terms is often a fraction of the raw strings, and it supports prefix and range lookups for free. Lucene has used them for years for this reason.

The **postings** are, for each term, the set of row positions containing it. Compressed bitmaps such as Roaring are the usual format: they pick a dense or sparse representation per block of 65,536 positions, and intersecting two of them for `a AND b` is fast.

Unlike everything above, an inverted index can work at row granularity. The scan reads the file, but only decodes the rows the bitmap names.

**When they pay:** token search over text, where neither bounds nor value sets can help.

**When they don't:** they're the biggest of these structures, and the most frequent terms have the biggest postings while being the least useful for skipping, since they're in every file anyway. Any real inverted index needs a size budget, and that budget raises a correctness question I come back to below.

### Sketches

Some structures don't skip anything. A HyperLogLog or theta sketch estimates how many distinct values a column has in a few kilobytes, and sketches from different files merge into a sketch of the union.

Their job is to feed the optimizer: join order, aggregation strategy and memory sizing all depend on cardinality. A sketch that's off by 2x doesn't return a wrong result. It quietly picks worse plans, which is harder to notice.

### Value-to-file maps

At the partition level you can invert the value set: for each value, a bitmap of which files in the partition contain it. One small read at planning time then narrows hundreds of files to the handful worth opening, without touching any per-file index.

This is the structure that addresses the "opened a thousand files to find three" problem directly. Its cost is that it has to be maintained as files come and go, and it needs the same cap-and-give-up rule as value sets.

## Choosing

| The predicate looks like | Data layout | Reach for |
|---|---|---|
| range on a time or sequence column | sorted or clustered | min/max bounds, which you already have |
| equality or `IN` on a low-cardinality column | any | value sets, with a cap |
| equality on an ID or key | any | bloom filters per file or row group |
| token in a text column | any | inverted index or token blooms |
| "which files have value *x*?" across many files | any | value-to-file map at the partition |
| nothing, it's the optimizer asking | any | sketches |

Two questions decide most cases before any of this. Is the skipping limited by layout, so that sorting the data would make the free bounds work? And at which level is the cost: in files opened, or in rows decoded?

## Where they live: Iceberg Puffin

Parquet and Iceberg manifests already carry bounds and counts. Anything beyond that needs a home, and Iceberg's answer is **Puffin**.

A Puffin file is deliberately simple. It starts with the four magic bytes `PFA1`, then any number of **blobs** (opaque byte ranges), then a footer: the magic again, a JSON payload describing every blob, the payload's length, four bytes of flags, and the magic once more. A reader fetches the end of the file, finds the footer, and from the JSON learns each blob's type, byte range, compression codec, the columns it covers, and the snapshot it was computed for. Blobs can be compressed individually, so a reader pulls only the blobs it needs, with ranged reads.

The spec defines two blob types:

- **`apache-datasketches-theta-v1`**: a theta sketch of a column's distinct values, with the estimate also stored as a property for readers that don't want to deserialize the sketch.
- **`deletion-vector-v1`**: a Roaring bitmap of deleted row positions in one data file, introduced with the v3 format.

Table metadata points to Puffin files through **statistics** entries, one per snapshot, each listing the blobs it holds. That's the important detail for anyone planning to put skipping indexes in Puffin: the spec's statistics are table-level and tied to a snapshot. Deletion vectors are the exception, referenced from the manifest entry of the data file they apply to. For a custom per-file or per-partition index, the format is ready (any blob type you like, read with a ranged request) but where the files live and how a reader finds them is the engine's decision. And an index written for snapshot *n* says nothing about files added in *n*+1.

## What building them taught me

Most of what went wrong this year wasn't in the structures. It was in the plumbing around them: what happens when a build is incomplete, when files are compacted, when two copies of an index disagree. Each lesson below came from a real bug or a near miss.

{% include diagrams/bloom-union.svg %}

**An incomplete index is a lying index.** If the index is built while writing, and the indexer falls behind and skips even one batch, the result says "not here" about values that are there. The only safe response is to throw the whole index away. A missing index costs performance. A partial one costs correctness.

**Caps must degrade to "maybe", and stay there through merges.** When two files merge, their value sets union. If either side had given up, the merged set has given up too, even if the values that were recorded add up to only a few. The ones that weren't recorded are still in the data. Re-applying the cap on a union of two incomplete sets produces a confident, wrong answer.

**Unions of bloom filters fill up.** Two bloom filters merge with a bitwise OR, but only if they have the same size and hash functions. And the union of *N* filters is fuller than any of them: with per-file fill *f*, the union's fill is 1 − (1 − *f*)^*N*. At 1% fill per file and *k* = 7, a union of 100 files is about 63% full and lies about 4% of the time. A union of 300 is 95% full and lies 70% of the time. A partition-level bloom built as an OR of per-file blooms has to be sized for the partition, not the file, or it should be checked for fill before anyone trusts it. I now write a fill check next to every bloom: above a threshold, don't emit it, and on the read side, don't trust it.

**Compaction is where indexes go to die.** When small files merge into big ones, each index has three options: carry it forward (rebase row positions, union the sets), rebuild it from the merged rows, or drop it. Dropping is safe but silent: queries just get slower and nobody knows why. Carrying forward is cheap but has to respect every rule above. Rebuilding is the most expensive and the most correct. The bug I least want to repeat was a merge that kept the **wrong copy** of an index when two generations existed for the same file, and the reader then skipped files that matched. A stale index is worse than none.

**A budget needs a record of what it dropped.** An inverted index with a size budget will drop terms, usually the frequent ones. If the reader can't tell "this term never appeared" from "this term was dropped", the budget has turned into false negatives. Whatever drops entries has to leave enough behind for the reader to know to fall back to a scan.

**Hashes must be stable across builds.** Sketches and blooms built by one build of the writer get merged with ones built by the next. If the hash function isn't specified (a language's default hasher, for example, which may change between compiler versions), merged structures silently stop agreeing. Pick a hash with a written specification and pin it.

**Count requests, not just bytes.** A reader that fetches one small index file per data file can spend more time on index requests than the index saves. This is why the partition-level structures exist, and why a single read of a small file beats several ranged reads of it.

**Test the property, not the example.** Example-based tests of these structures pass easily, because examples are small and friendly. What found real bugs for me was randomized property testing with replayable seeds: for any random set of values, nothing inserted is ever reported absent; a union reports every member of every input; the parser never crashes on arbitrary bytes. That suite found a crash in a footer parser on malformed input, and a sketch that roughly doubled its estimates above a certain cardinality, hidden below it by the small-range correction every test happened to exercise.

## The short version

Skipping indexes are a hierarchy of cheap questions, each one asked so that a more expensive question never has to be. Pick the granularity where the cost is, pick the structure the predicate needs, store it where the reader can fetch it in one request, and treat every way it can go stale or incomplete as a correctness bug, because that's what it is.
