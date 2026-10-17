---
layout: post
title: "Blitz: a file format for vectors on object storage"
redirect_from: /journal/blitz-a-file-format-for-vectors/
chapter: 6
period: "25 February 2025"
dek: "Vector search wants a handful of vectors out of millions, at full precision, from storage that charges you per request. No format we tried was built for that, so we wrote a small one that was."
---

The [previous post](/notes/what-we-tried-and-threw-away/) ended with a vector database library taken back out of the engine and a decision to write our own format. Three days later, on 6 January, the first version of **Blitz** went in. By the end of February it had the shape it kept. I talked about it at Rootconf in 2025. This is the written version, with a bit more of the reasoning.

## What the access pattern looks like

Start from what a vector query actually does. "Find the ten reviews closest to *battery dies too quickly*" means:

1. look at every candidate vector, cheaply, to work out which few are close,
2. read those few at full precision to rank them properly,
3. return ten rows.

Step 1 touches everything but needs very little of each vector. Step 3 needs very little data at all. Only step 2 needs real precision, and only for a handful of vectors.

Now put that on object storage. The cost model there is simple. Every request has a fixed latency and, in most clouds, a price. Bytes are relatively cheap once a request is in flight. A good file format for object storage keeps the number of requests small and makes each one count.

General-purpose formats are built for a different pattern: scan a lot of rows, a few columns at a time, and compress well along the way. Floating-point embeddings barely compress. Pulling ten specific vectors out of a compressed columnar file means downloading and decoding the whole pages they live in. Nothing in a Parquet file says "row 48,213 starts at byte X".

## The design

Blitz has two parts, and the second one is the important one.

**The body** is just the vectors, stored as raw 32-bit floats, one after another. No compression and no encoding. A vector of *d* dimensions is exactly 4*d* bytes, so it can be read with a single ranged request of a known length.

**The footer** is the index. For every row it holds:

- the row's position in the matching data file,
- the byte offset of that row's vector in the body,
- a **binary-quantized** copy of the vector, one bit per dimension, as described in the previous post.

The file ends with the footer's own offset in its last eight bytes, the same trick Parquet uses. A reader can always find its way in with one small read at the end of the file.

There's one Blitz file per data file. That's the decision from [the vectors post](/notes/vectors-inside-a-sql-engine/) carried through: vectors stay aligned with the data they describe, so when a data file is pruned, its vectors go with it.

{% include diagrams/blitz-layout.svg %}

## Reading it: two passes

Answering a nearest-neighbour query against one Blitz file goes like this:

1. **Read the footer.** One request for the tail, one for the footer. Footers are cached across queries, along with the file length, so a warm query doesn't even need those.
2. **First pass, entirely in memory.** Binary-quantize the query vector once. For each row that survived pruning and the query's filters, compute the Hamming distance between its bits in the footer and the query's bits. That's an XOR and a popcount per word. Keep the closest *K*, where *K* comes from the query's `LIMIT`, pushed down to the scan.
3. **Second pass, a few targeted reads.** Look up the byte offsets of those *K* rows. Sort the ranges, merge any that sit close together, and fetch them with parallel ranged reads. Compute the exact distance on the full-precision vectors.
4. **Merge across files.** Each file contributes its own top *K*. A final operator collects every file's candidates, already scored at full precision, and orders them into the global top *K*.

The arithmetic is what makes it work. A 1,536-dimension embedding is 6 KB at full precision and 192 bytes as bits, 32 times smaller. The first pass runs over the small copies, which already sit in memory. The second pass touches a handful of full vectors with a handful of requests. Nothing reads the whole body.

## What I'd do the same way again

**Put the index in the footer.** The decision a reader has to make comes before any expensive read, so everything needed to make it lives in one place that can be fetched and cached in one go.

**Keep the body boring.** Fixed-size, uncompressed records mean offsets are trivial, reads are exact, and there's nothing to decode. The cleverness belongs in the footer, not in the bytes on disk.

**Count requests, not bytes.** Sorting and merging nearby ranges before fetching is cheap to do, and on object storage it goes straight at the cost that matters.

**Own the small thing.** The writer and reader together are a few hundred lines. Being small enough to read in one sitting, and to debug with a hex dump, is a real feature for a format that sits on a query's critical path.

## What it doesn't do

It's worth being clear about the edges:

- **The footer grows with the row count.** Every row has an entry, so very large data files mean large footers. That's fine while footers fit comfortably in a cache, and it's the first thing I'd revisit for much larger files.
- **Recall depends on the first pass.** Binary quantization is a rough estimate. How many candidates survive into the exact pass is the knob that trades recall against reads, and it deserves more attention than a default.
- **It's an exact-rerank design, not a graph index.** There's no HNSW-style structure here. For analytical queries that filter first and then rank, that was the right trade. For a pure similarity-search service at very large scale, it might not be.

Blitz went behind a feature flag in March, picked up its own reader and writer tests the same week, and was merged in the summer. The next stretch of work moved from making one machine fast to making many machines cooperate.
