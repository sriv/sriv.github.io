---
layout: post
title: "Bloom filters at the scan"
chapter: 2
period: "July 2024"
dek: "Parquet already knows how to say \"this value isn't here\". Getting an engine to ask cheaply, and to never trust a wrong answer, was the actual work."
---

The [last chapter](/journal/the-cheapest-row-is-the-one-you-never-read/) ended on point lookups: `WHERE order_id = 42` on a big table, where min/max statistics are useless because every row group spans the whole range of IDs. In July 2024 that was the first thing I went after.

Parquet has an answer to this built in. A writer can store a **bloom filter** for a column in each row group. Ask it "could 42 be in this row group?" and it says either "no" or "maybe". If it says no, it's right. If it says maybe, it's right most of the time, and the rest of the time you pay for a read that finds nothing.

That's exactly the "maybe, never a wrong no" shape from chapter 1. On paper, the job was small: read the bloom filter, ask it, skip the row group on a "no". The bloom filter turned out to be the easy part.

## Where the check goes

The first decision was where in the scan to ask the question. There are two natural places.

**Per row group, inside the reader.** The reader has the footer, so it knows where each row group's bloom filter lives. Before fetching a row group's column chunks, read the bloom for the filter column, test the value, skip on "no". This is simple and local, and it saves the expensive part: the column chunk fetch, decompression and decode.

**Per file, before the task is handed out.** If every row group in a file says "no", the whole file can go. Doing that before the scan task is created saves even more: no task, no footer read on the executor, nothing.

{% include diagrams/bloom-check.svg %}

I did the first one first, because it was self-contained and easy to test, and then added the second one in the part-file pruning step once the first was trustworthy. The two share everything except where they sit. That turned out to matter more than which one was "right", because the piece they share became the most important part of the design.

## The bloom filter is a network read

Here's what the paper version leaves out. On object storage, reading the bloom filter is itself a remote read. It's small, a few kilobytes to a few hundred kilobytes per column per row group, but it is still a GET with its own latency. For a file with many row groups, asking every bloom filter on every query can cost a noticeable fraction of what you were trying to save.

I spent a while on this, including reading the bloom filters as one batch of vectored ranges instead of one after another. Either way, the real fix was not to read them again at all. Data files in an Iceberg or Delta table are immutable: a path, once written, never changes, and compaction writes new files rather than rewriting old ones. So a bloom filter read once is good for as long as the file exists. (Plain directory-based tables can rewrite a file in place, which is a good reason to put the file's size or modification time into the cache key as well.)

So we put a cache in front of the reader: in-process, keyed by file, row group and column, holding the bloom filters we'd already read. We called it the **index store**, because I already suspected it would end up holding more than Parquet's own filters. The first query against a file pays for the bloom reads. Every query after that asks the cache.

The store also has a default that I think is the most important line in the whole feature. If there is no entry for a key, the answer is "maybe". A missing index never prunes anything. It just means you read the data, the same as before the feature existed.

## A bug that proved the default

That default earned its keep within a week. We found that the code registering a bloom filter and the code looking it up built the file path slightly differently, so lookups missed. Every miss returned "maybe", every affected row group was read, and the results stayed correct. The only symptom was that pruning didn't prune.

That's the failure mode you want. A cache-key bug in a pruning structure should cost you performance, never correctness. If the default had been "not found means not present", the same one-line bug would have silently dropped rows from query results, and we might not have noticed for a long time. The fix was a few characters. The lesson was to design the store so that every kind of mistake falls on the slow side.

## Committing an index, not just caching one

The other thing the store needed was a lifecycle. A scan task can fail halfway: the executor is under memory pressure, a read times out, the task gets cancelled. If the reader has registered half of a file's bloom filters by then, what state is the store in?

For bloom filters read straight from Parquet this is mostly harmless, since each filter is complete on its own. But I already knew where this was heading. The next step was going to be indexes the engine builds for itself while scanning, and a half-built index is exactly the kind of structure that can give a wrong "no".

So entries in the store got a **commit and rollback**:

- while a task is reading, any index it builds is transient and invisible to other queries,
- when the task finishes reading the file cleanly, it commits, and the entries become visible,
- if the task fails or is cancelled, it rolls back, and the transient entries are dropped.

It looks like a lot of ceremony for a cache. It's the part of this work I'm happiest we did early, because everything in the next chapter depends on it.

## What I'd do the same way again

Two things from that month that I still apply:

- **Make "unknown" the safe answer.** Any structure that can skip work should treat missing or broken metadata as "read it". Then bugs show up in latency graphs rather than in someone's quarterly numbers.
- **Price the metadata read.** On object storage, metadata isn't free. Cache anything immutable, and measure how much time goes into asking the index before celebrating what the index saves.

There was one more lesson that set up the next chapter. Most Parquet files in the wild don't have bloom filters at all. Common writers leave them off by default, and you rarely control the writer. If we wanted bloom-filter pruning on the tables people actually had, the engine would have to build the filters itself, from the data it was already reading.

That's chapter 3: letting the queries build the index.
