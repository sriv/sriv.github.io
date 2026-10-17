# Blitz: a file format for vectors on object storage

By Srikanth Venugopalan, 25 February 2025. Topics: vectors, file formats.
Canonical: https://sriv.github.io/notes/blitz-a-file-format-for-vectors/

> Vector search wants a handful of vectors out of millions, at full precision, from storage that charges you per request. None of the formats I tried did that well in my setup, so I wrote a small one that did.

[What I tried and threw away](https://sriv.github.io/notes/what-we-tried-and-threw-away/) ended with a vector database library taken back out of the engine and a decision to write my own format. Three days later, on 6 January, the first commit of **Blitz** landed. By the end of February it had the shape it kept. I talked about it at Rootconf in 2025. This is the written version, with a bit more of the reasoning.

## What the benchmarks said first

Blitz didn't start as a design. It started as a few weeks of reading and benchmarking in December, trying to answer one question before writing any code: which existing format can hand back a few specific vectors, fast, out of a large file?

The test was deliberately plain. Random 1,024-dimension float vectors, a hundred thousand of them and then a million and more, and two workloads: read everything, and fetch a thousand vectors at random. Four candidates:

- **Parquet, as usual.** Fine for reading everything at the smaller sizes, which is what it's built for.
- **Parquet, transposed**, so that each vector became its own column and could be read in one contiguous piece. Reads came out roughly sixty times slower than plain Parquet. Worse, at a million vectors neither Parquet layout I'd built could even be opened: with the row-group settings I was using, the footer outgrew the reader's limit on how large its metadata could be.
- **Lance**, which was designed with vectors in mind. Its full scans kept up with Parquet. Random fetches through the integration I had then were the slower of the two formats that still opened at a million vectors. That says more about my integration than about the format.
- **Avro**, using a sorted key-value file with an index alongside. Random fetches stayed flat from a hundred thousand vectors to two million, because the index points straight at the record. Then I varied how often the index records an entry. Going from every record to every two-thousandth record made random fetches more than a thousand times slower.

Two things from that study ended up in the format almost directly. A footer whose size depends on the wrong thing will eventually stop a file from opening. Blitz's footer grows only with the rows of its own data file, which the writer controls. And for random access, the density of the index sets how many bytes each lookup drags in: with an entry every two thousand records, every lookup reads up to two thousand records. Blitz's footer has an entry for every row.

## What the access pattern looks like

Start from what a vector query actually does. "Find the ten reviews closest to *battery dies too quickly*" means:

1. look at every candidate vector, cheaply, to work out which few are close,
2. read those few at full precision to rank them properly,
3. return ten rows.

Step 1 touches everything but needs very little of each vector. Step 3 needs very little data at all. Only step 2 needs real precision, and only for a handful of vectors.

Now put that on object storage. The cost model there is simple. Every request pays a high first-byte latency and, on the major clouds, a price. Bytes are relatively cheap once a request is in flight. A good file format for object storage keeps the number of requests small and makes each one count.

General-purpose formats are built for a different pattern: scan a lot of rows, a few columns at a time, and compress well along the way. Floating-point embeddings barely compress. Pulling ten specific vectors out of a compressed columnar file means downloading and decoding the whole pages they live in. Parquet's offset index can tell you which page holds row 48,213 and where that page starts, but not where the row itself starts, so you still fetch and decode the whole page.

## The design

Blitz has two parts, and the second one is the important one.

**The body** is just the vectors, stored as raw 32-bit floats, one after another. No compression and no encoding. A vector of *d* dimensions is exactly 4*d* bytes, so it can be read with a single ranged request of a known length.

**The footer** is the index. For every row it holds:

- the row's position in the matching data file,
- the byte offset of that row's vector in the body,
- a **binary-quantized** copy of the vector, one bit per dimension, as described in [What I tried and threw away](https://sriv.github.io/notes/what-we-tried-and-threw-away/).

The file ends with the footer's offset in its last eight bytes, much like Parquet, which keeps its footer length and a magic number there. A reader can always find its way in with one small read at the end of the file.

There's one Blitz file per data file. That's the decision from [the vectors post](https://sriv.github.io/notes/vectors-inside-a-sql-engine/) carried through: vectors stay aligned with the data they describe, so when a data file is pruned, its vectors go with it.

[Diagram: A Blitz file: a body of raw float32 vectors, a footer with each row's position, byte offset and binary-quantized bits, and an eight-byte footer offset at the end. Reading takes three steps: read the tail and footer (cached), compute Hamming distances in memory to keep the closest K, then issue ranged reads for only those K full vectors and rerank them exactly. Each file returns its own top K, merged in a final step.]

*The footer decides; the body only answers for the few rows the footer picked.*

## Reading it: two passes

Answering a nearest-neighbour query against one Blitz file goes like this:

1. **Read the footer.** One request for the tail, one for the footer. Footers are cached across queries, along with the file length, so a warm query doesn't even need those.
2. **First pass, entirely in memory.** Binary-quantize the query vector once. For each row that survived pruning and the query's filters, compute the Hamming distance between its bits in the footer and the query's bits. That's an XOR and a popcount per word. Keep the closest *K*, where *K* comes from the query's `LIMIT`, pushed down to the scan.
3. **Second pass, a few targeted reads.** Look up the byte offsets of those *K* rows. Sort the ranges, merge any that sit close together, and fetch them with parallel ranged reads. Compute the exact distance on the full-precision vectors.
4. **Merge across files.** Each file contributes its own top *K*. A final operator collects every file's candidates, already scored at full precision, and orders them into the global top *K*.

The arithmetic is what makes it work. A 1,536-dimension embedding is 6 KB at full precision and 192 bytes as bits, 32 times smaller. The first pass runs over the small copies, which already sit in memory. The second pass touches a handful of full vectors with a handful of requests. Nothing reads the whole body.

## What I'd do the same way again

**Put the index in the footer.** The decision a reader has to make comes before any expensive read, so everything needed to make it lives in one place that can be fetched and cached in one go.

**Keep the body boring.** Fixed-size, uncompressed records mean every read has an exact, known length, and there's nothing to decode. The cleverness belongs in the footer, not in the bytes on disk.

**Count requests, not bytes.** Sorting and merging nearby ranges before fetching is cheap to do, and on object storage it goes straight at the cost that matters.

**Own the small thing.** The writer and reader together are a few hundred lines. Being small enough to read in one sitting, and to debug with a hex dump, is a real feature for a format that sits on a query's critical path.

## What it doesn't do

It's worth being clear about the edges:

- **The footer grows with the row count.** Every row has an entry, so very large data files mean large footers. That's fine while footers fit comfortably in a cache, and it's the first thing I'd revisit for much larger files.
- **Recall depends on the first pass.** Binary quantization is a rough estimate. The first pass keeps exactly *K* candidates. Keeping a few multiples of *K* would trade more reads for better recall, and that knob deserves more attention than a default.
- **It's an exact-rerank design, not a graph index.** There's no HNSW-style structure here. For analytical queries that filter first and then rank, that was the right trade. For a pure similarity-search service at very large scale, it might not be.

In March Blitz picked up its own reader and writer tests and a feature flag, and it was merged to main in the summer. The next stretch of work moved from making one machine fast to making many machines cooperate.
