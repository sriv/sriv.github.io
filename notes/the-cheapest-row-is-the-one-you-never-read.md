# The cheapest row is the one you never read

By Srikanth Venugopalan, 31 May 2024. Topics: engines, pruning.
Canonical: https://sriv.github.io/notes/the-cheapest-row-is-the-one-you-never-read/

> Before indexes, vectors or distributed anything, I had to learn where a query engine actually spends its time. The answer: reading things it didn't need.

At the end of May 2024 I moved onto the execution side of our query engine. It's a pipelined, vectorized engine written in Java that runs SQL over Parquet files sitting in object storage. I'd used engines like this for years. I had never had to make one faster.

My instinct was to go looking for a slow operator, a join that spilled or an aggregation that hashed badly. So I spent the first couple of weeks with a profiler and a set of slow queries, and the profiles kept telling me something else. The joins and aggregations weren't where the time went. It went into getting bytes off object storage, decompressing them, and turning them into column vectors, often for rows that a filter would throw away two operators later.

That changed how I thought about the next two years of work, so it seems like the right place to start these notes.

## How a query actually runs

The planner turns SQL into a tree of physical operators: scan, filter, project, join, aggregate. The executor cuts that tree into **pipelines**, chains of operators that can pass data along without waiting. A pipeline ends wherever an operator has to see all of its input before it can produce anything. Building the hash table for a join is one of those points. Sorting is another.

Data moves through a pipeline in **batches**. Each batch is a set of column vectors, a few thousand rows per column, and each operator works on a whole batch at a time instead of row by row. That's the "vectorized" part, and it's why these engines are fast once the data is in memory.

[Diagram: The six steps of a Parquet scan on object storage. The later a row is rejected, the more it has already cost.]

*The scan, top to bottom. Every step down is more work spent on rows the filter may throw away.*

The scan sits at the bottom of every pipeline, and on a lakehouse it does a lot more than "read a file". For a Parquet file on S3 it has to:

1. work out which files belong to the query (table metadata, partitions),
2. read each file's footer to find the row groups and column chunks,
3. fetch the column chunks it needs, as ranged GETs over the network,
4. decompress the pages,
5. decode them into vectors,
6. and only then hand them to a filter that might drop 99% of the rows.

Every step costs something, and the cost compounds. A row you reject at step 1 cost you almost nothing. A row you reject at step 6 cost you a network round trip, a decompression and a decode, and you got nothing for it.

## The ladder of skipping

Once you see the scan this way, the question changes from "how do I make the filter faster?" to "how early can I find out that I don't need this data?" Engines answer it with a ladder of increasingly fine-grained structures:

- **Partition pruning.** If the table is partitioned by day and the query asks for one day, skip every other day. Free, but only helps queries that filter on the partition column.
- **File and row-group statistics.** Parquet keeps min/max values per column per row group. If the query wants `amount > 1000` and a row group's max is 400, skip it without reading a byte of data.
- **Page-level indexes.** The same idea, one level down.
- **Late materialization.** Read and filter the predicate column first, then fetch the other columns only for the rows that survived.

Each rung is cheaper than the one below it, and each one is useless for some query shape. Min/max statistics are the clearest example. They work beautifully on columns where values cluster, like timestamps in an append-only table. They do almost nothing for a column like `user_id` or `order_id`, where every row group contains a spread of values from the smallest to the largest. The min is small, the max is large, and every row group "might" contain the value you're looking for.

A lot of real queries are exactly that shape: find this customer, this order, this session. Point lookups on high-cardinality columns are where min/max pruning falls over and where the engine ends up reading close to the whole table to return a handful of rows.

## The decision: skip before you speed up

So the first real call I had to make was where to spend effort. There were two options:

- make the hot path faster: better decoding, fewer copies, smarter vector layouts,
- make the hot path run less often, by giving the scan more ways to say "not this file" or "not this row group".

The first one is the more satisfying engineering. It is also capped. A 2x faster decoder is a great result, and it still decodes every row you didn't need.

The second one isn't capped in the same way. If a lookup goes from reading 2,000 row groups to reading 3, no decoder optimization competes with that. I decided to spend most of my time on the second, and the other notes here are about what that turned into: bloom filters at the scan, then indexes the engine builds for itself from the queries it runs.

The trade-off is that every skipping structure you add is something else to build, store, keep fresh and trust. Which brings me to the rule I kept coming back to.

## The one rule: maybe, never a wrong no

A pruning structure is allowed to be imprecise in one direction only. It can say "this row group *might* have matching rows" when it doesn't. That costs you a wasted read, nothing more. It must never say "this row group has no matching rows" when it does, because then the query silently returns the wrong answer.

Bloom filters fit this naturally. A bloom filter gives false positives but no false negatives. Min/max statistics fit it too, as long as they're computed correctly. Where it gets dangerous is anything the engine builds or caches for itself, because now the engine is responsible for keeping that structure in step with the data. A stale index that says "no" after new data lands is the worst kind of database bug: nothing crashes, the numbers are just wrong.

Every design in the other notes had to survive that rule first and be fast second.

## What I'd tell someone starting on this

Measure bytes, not just time. For each slow query, look at how many bytes the scan fetched against how many bytes the final result actually depended on. That ratio tells you whether you have a compute problem or a "reading things you didn't need" problem. In my experience it's usually the second one, and that's the cheaper one to fix.

Next: pushing bloom filters down to the scan, and why the filter itself was the easy part.
