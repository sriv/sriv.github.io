---
layout: post
title: "What we tried and threw away"
redirect_from: /journal/what-we-tried-and-threw-away/
chapter: 5
period: "3 February 2025"
dek: "Three experiments that didn't make it: virtual threads for the executor, a vector database library, and product quantization. Each one taught me something the successes didn't."
---

Engineering write-ups tend to read like a list of things that worked. This post is the other list. Over those few months I tried at least three things that never shipped in the form I first built them. I think they're worth writing down, partly because each one changed what we did next, and partly because knowing when to stop is a skill I've had to learn on purpose.

## Virtual threads for the executor

In September 2024 Java 21's virtual threads were the exciting new thing in the JVM world. Our executor runs a lot of concurrent work on thread pools, so the obvious experiment was to swap the pools' thread factories for virtual threads and see what happened. The change itself was small. I did it on a branch, ran it, and it never went to main.

The lesson was about what virtual threads are for. They make *blocking* cheap: a virtual thread waiting on the network or a lock gets parked and its carrier thread goes off to do something else. An executor's pipeline workers mostly aren't waiting. They're decoding Parquet pages and running vectorized operators, which is CPU work. Putting CPU-bound work on virtual threads doesn't make it faster, and on Java 21 it brings its own surprises, such as virtual threads getting pinned to their carrier inside `synchronized` blocks.

Virtual threads did end up in the codebase later, in exactly the place they suit: the vector loading path, where a thread spends most of its life waiting for an embedding server to reply. Same feature, different job, and that time it was the right call.

**What I took from it:** match the concurrency tool to what the threads actually spend their time doing. Profile first, then pick the tool.

## A vector database library inside the engine

When we started on vector search ([the vectors post](/notes/vectors-inside-a-sql-engine/)), one tempting shortcut was to borrow from a project that had already solved vector storage. In December I pulled a vector database library into the executor so I could benchmark its format against Parquet and Avro for reading embeddings.

It came out again on 3 January.

That wasn't a verdict on the library. The question I was really asking was "should our engine's scan path depend on this?", and the answer was no. Taking a dependency like that into the core of a query engine means taking on its release cycle, its memory model and its idea of how files should be laid out and read. Our scan path already had strong opinions about all three: per-file alignment with the table's data, our own caching, our own I/O. We'd just spent months teaching the engine to read fewer bytes, and a library that owns its own file layout would have sat outside all of that. What I needed was a format that fit those opinions, and three days after removing the library we started writing one. That's the next post.

**What I took from it:** benchmark against the best available option even when you suspect you won't adopt it. It tells you what "good" looks like, and it makes the case for building your own honestly instead of by default.

## Product quantization

The third experiment was about making brute-force vector search cheaper. Exact search reads every candidate vector at full precision. Quantization compresses vectors so the first pass reads far less.

**Product quantization** (PQ) is the classic approach. Split each vector into sub-vectors, run k-means on each slice of the dataset to learn a small codebook, and store each sub-vector as the ID of its nearest codebook entry. You get large compression and decent distance estimates.

In late January I built a PQ prototype on a branch. It never made it to main.

PQ needs **training**. The codebooks are learned from the data, so every table needs a k-means step before its vectors can be compressed, and codebooks drift as data changes. For a search service with one big, stable index that's a fine trade. For an engine where vectors arrive with each new data file, it's an extra build step with its own failure modes and tuning, on the critical path of every load.

A week later I tried the much blunter tool, **binary quantization**: keep one bit per dimension, its sign. No training, no codebooks, nothing that drifts. Distances become a Hamming distance, which is an XOR and a population count, about the cheapest thing a CPU can do. The estimates are much rougher than PQ's, so it can't answer a query on its own. But it doesn't need to. It's a first pass that throws away the obviously far vectors, followed by an exact rerank of the survivors at full precision.

{% include diagrams/quantization.svg %}

**What I took from it:** prefer the technique whose costs match the system's shape. PQ is better at compression. Binary quantization was better for an engine that loads data continuously and already knows how to do an exact second pass.

## On stopping

None of these were mistakes, and none of them were wasted. Each one ran for weeks at most. Each one lived on a branch until it earned its way into main, and each one changed the next decision: where to use virtual threads, whether to build our own vector format, which quantization to use.

The pattern I try to follow now is simple. Give an experiment a question to answer, not a feature to ship. When it has answered the question, stop, even if the answer is "no", and write down why. The writing-down part is the one I'm most tempted to skip, and it's the only thing that stops someone, often me, from running the same experiment again a year later.
