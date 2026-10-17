# Vectors inside a SQL engine

By Srikanth Venugopalan, 17 December 2024. Topics: vectors.
Canonical: https://sriv.github.io/notes/vectors-inside-a-sql-engine/

> Most teams I talked to were standing up a separate vector database. I tried making similarity search just another thing our query engine could do.

At the end of 2024 every conversation about search seemed to start with "which vector database?". The usual shape was a second system next to the warehouse: copy the text out, embed it, load the vectors into a dedicated store, and join the results back to the tables in application code.

We already had an engine that was good at scanning large tables in object storage, with the indexes and pruning from [bloom filters](https://sriv.github.io/notes/bloom-filters-at-the-scan/) and [lazily built indexes](https://sriv.github.io/notes/let-the-queries-build-the-index/). In November I started on the other option: make similarity search something the SQL engine does itself, over the tables people already have.

## The decision: a column, not a database

The core choice was how a user should see vectors. There were two shapes.

**Vectors as data the user manages.** The table gets an `embedding` column of floats. The user computes embeddings somewhere, writes them in, and queries with distance functions over that column. This is flexible and simple, and it pushes the hard work back onto the user.

**Vectors as something the engine maintains for a text column.** The user says "make `review_title` searchable". The engine computes embeddings for that column and stores them next to the data. At query time the user writes something like:

```sql
SELECT review_title, rating
FROM reviews
ORDER BY cosine_distance(review_title, 'battery dies too quickly')
LIMIT 10;
```

The engine embeds the query string once, compares it against the stored vectors for `review_title`, and returns rows. The user never touches a vector.

I went with the second. A query engine's job is to hide physical layout from the person writing SQL. Making them handle 768 or 1,536 floats per row felt like the same mistake as making them pick which Parquet row groups to read. The embeddings became, in effect, a hidden column the engine owns: created by a separate `LOAD VECTOR` job rather than inside anyone's ingestion pipeline, kept beside the table's own files, and used only through functions like `cosine_distance`.

[Diagram: At load time, a text column is sent through an in-cluster embedding model and the vectors are written beside each data file. At query time, the query string is embedded once, the vectors of files that survive pruning and filters are scanned with an exact distance, and the top results are returned.]

*Embeddings are a column the engine owns. Load once; at query time, embed the question and scan what survives pruning.*

## Embeddings at load time

Computing an embedding is the expensive part, so the first question was when to do it. At query time is a non-starter: embedding every row on every query costs far more than the search. So `LOAD VECTOR` runs as its own job: scan the text column, send batches to an embedding model, write the vectors out alongside the data files they came from.

My first version called a hosted embedding API. That was enough to get the load path working end to end, and it also made the trade-offs obvious: every row of the customer's text leaves the cluster, throughput depends on someone else's rate limits, and cost scales with table size. Within a week I'd moved the load path onto a self-hosted embedding server running next to the engine. Same interface, but the model runs where the data is and the throughput is ours to scale.

The detail that mattered most was keeping vectors aligned with the files they describe. Each data file gets its own set of embeddings, so when the engine prunes a file using its indexes and statistics, it skips that file's vectors too. Similarity search inherits the scan's pruning for free, and filters like `WHERE rating < 3` cut down the work before any distance is computed.

## Brute force, on purpose

The other big decision was not to start with an approximate index.

Most vector databases lead with an approximate index, such as HNSW graphs or IVF clusters. They answer "the nearest 10 vectors" without looking at most of them, at the cost of sometimes missing a true neighbour. They're the right tool for a dedicated, latency-sensitive search service.

I started with exact search: compute the distance to every candidate vector and keep the best. Three reasons:

- **It's always right.** Exact search is the baseline you measure every approximation against. Starting there meant I'd know exactly what I gave up later.
- **It composes with SQL.** A plain approximate index answers "nearest overall". Filtered variants exist, but keeping recall up when the filter is selective is still hard. Real queries say "nearest among the reviews from last month with rating under 3". With an exact scan, the filter runs first and the distance is computed only on what's left. Combining selective filters with approximate indexes is a well-known source of quietly bad results, such as too few rows or missed neighbours.
- **An analytical engine is good at scans.** Splitting the scan across files and executors, computing distances in vectorized batches, and merging each part's best results is exactly the kind of work the engine already does well.

The cost is obvious: you read every surviving vector. That is fine when filters and pruning have already cut the candidates down, and expensive when they haven't. It set up the next two months of work: making that read as cheap as possible.

## Where to keep the vectors

The last open question in December was physical: what format should the vectors be stored in? There were three obvious candidates. Parquet, because everything else was Parquet. Avro, because it stores each vector's floats as one simple array, without Parquet's per-element list encoding. And Lance, a newer columnar format built with vectors in mind.

I wrote benchmarks to read embeddings through all three in the engine's own scan path. [What I tried and threw away](https://sriv.github.io/notes/what-we-tried-and-threw-away/) covers why I didn't adopt any of them, and how that led to writing my own format in January.

## What I'd tell a team starting on this

- **Decide who owns the embeddings.** If users own them, you've built a distance function. If the engine owns them, you've built a feature. The second is more work and much more useful.
- **Start exact.** Get exact search right, with filters, before adding anything approximate. You'll need it as the reference anyway.
- **Align vectors with data files.** Then every pruning trick you already have applies to vector search without extra work.
