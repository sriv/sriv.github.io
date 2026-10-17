# Let the queries build the index

By Srikanth Venugopalan, 4 December 2024. Topics: indexes.
Canonical: https://sriv.github.io/notes/let-the-queries-build-the-index/

> Most Parquet files don't carry bloom filters, and we didn't control the writers. So the engine started building its own indexes from data it was reading anyway.

[The bloom filter post](https://sriv.github.io/notes/bloom-filters-at-the-scan/) ended on an awkward fact. Bloom filter pruning works well when the Parquet file has bloom filters, and most files don't. Writers leave them off by default, and in a lakehouse the engine reading the table often isn't the system that wrote it.

So the question for the rest of 2024 was: if the files won't carry the index, can the engine build it?

## The decision: build it lazily

There were two ways to go about it.

**A background indexer.** A separate job walks the tables, reads the data, builds bloom filters or range indexes for chosen columns, and stores them. Queries find the index ready and waiting.

**Build it as a side effect of queries.** When a scan reads a column that's used in an equality filter, it has the values in hand anyway. Feed them into a bloom filter as the batch goes past, and store that filter for the next query.

The background indexer is the more conventional design, and it gives predictable query times. But it has to decide what to index before anyone asks, and unless something tells it otherwise, it spends compute on tables nobody queries. It also needs its own scheduling, its own failure handling, and something to tell it which columns matter.

The lazy approach gets the "which columns" question answered for free: the queries tell you. The first query against a file pays a small indexing cost on top of a read it was doing anyway. Every later query with a filter on that column can skip row groups. Tables nobody queries never get indexed. And there's no new service to run.

I went with lazy. The price is that the first query isn't faster, only the ones after it, and that the engine is now writing state it will later trust to skip data. The rule from [the cheapest row](https://sriv.github.io/notes/the-cheapest-row-is-the-one-you-never-read/), "maybe, never a wrong no", stops being a property of Parquet and becomes our problem.

[Diagram: A query's scan builds a transient filter. If the task saw every row it commits the filter to the index store; if it failed, was cancelled or stopped at a LIMIT, the filter is thrown away. Later queries use the store to skip row groups. Indexes are persisted to object storage and loaded back in the background after a restart.]

*The life of a lazily built index. The only path into the store goes through "saw every row".*

## Where a lazily built index can lie

Building the filter is easy. Building one that never gives a wrong "no" took most of the work, and almost all of it came down to one question: did this task see *every* row of the row group it's about to vouch for?

Some ways the answer can quietly be "no":

- **The task fails partway.** Half a file's values went into the filter, then the executor ran out of memory. That's what the commit and rollback from the bloom filter post were for. Nothing becomes visible until the task finishes the file cleanly, and a failed task throws its transient filters away.
- **The query stops early.** This is the one I'm glad I caught. A query with a `LIMIT` can stop reading a file as soon as it has enough rows. Its filter would only contain the values it happened to read before stopping, and a later query looking for a value further down the file would be told "no". So scans that can stop early don't build indexes at all.
- **Two tasks index the same file at once.** Both could build a filter and both try to commit. I made registration first-writer-wins, and only the task that registered a file builds its index, so a slower duplicate can't overwrite a finished one.
- **The batch was already filtered.** If anything removes rows before the builder sees them, say a cheap predicate pushed into the reader, the filter only knows about the survivors. A later query asking for one of the removed values gets a "no". The builder has to see rows before any predicate, or any delete file, touches them. This one comes back [when the reader underneath changed](https://sriv.github.io/notes/porting-an-idea-not-the-code/).
- **The column isn't what its name says.** Tables get columns renamed, and Delta tables can map logical column names to different physical ones. An index keyed on the name a query uses can end up describing the wrong data. I fixed this for mapped columns in August by keying on the physical column.
- **The filter is sized wrong.** A bloom filter is sized for an expected number of distinct values. Guess too low and it fills up and starts saying "maybe" to everything. That's not a correctness bug, but it quietly turns the feature off. Getting the expected number of distinct values right was an early fix.

None of these are exotic. They're the normal life of a scan task in a distributed engine. That's the point: an index built inside the query path inherits every way a query can end badly, and each one needs an answer before you trust the index to skip data.

## Indexing expressions, not just columns

Users don't always filter on a raw column. A common pattern is something like `WHERE SUBSTRING(order_ref, 1, 4) = 'EU01'`, or a `CAST` of a string column to a date. A bloom filter on `order_ref` can't answer that, because the stored values aren't the values being compared.

In August I extended dynamic indexes to expressions. The scan evaluates the expression, `CAST` or a nested `CAST(SUBSTRING(...))`, on the batch it's already reading, and puts the *results* into the filter. The tricky bit is the key. Two queries that cast the same column to different types must not share an index. So the index key includes the expression itself, the function, its arguments and the target type, not just the column name.

This went in behind its own flag. Expression indexes are more useful and more dangerous than column indexes, and I wanted to turn them on separately.

## Making it survive a restart

By October the indexes were useful enough that losing them hurt. Executors restart: deploys, spot reclamation, scaling down. Each restart threw away every index and put the next round of queries back on full scans.

So I made them persistent:

- indexes are written to object storage, starting with the range indexes, alongside metadata about which file and row group they cover,
- on startup, an executor **bootstraps** its indexes in the background rather than blocking startup on them,
- until an index is loaded, lookups return "maybe", the same as if it didn't exist.

That last point is the bloom filter post's default doing its job again. A slow or failed index load can't make a query wrong, only temporarily slower. The load has a timeout so one stuck read can't hold up the rest.

The in-memory store also needed a budget. Bloom filters for a big table add up. I made the store bounded, by entry count or by memory, switchable per deployment, so the index store can't grow until it takes an executor down. A colleague later added a guard that decides whether to index at all based on table size.

## What I'd tell a team starting on this

- **Decide who pays.** Lazy indexing makes the first query pay and rewards the rest. Make that trade on purpose, and write it down, because someone will eventually ask why the first query after a deploy is slow.
- **List every way a scan can end early or partially.** Failure, cancellation, `LIMIT`, sampling, retries. Each one is a way to commit an incomplete index. If your engine adds a new one later, it needs an answer too.
- **Every new kind of index gets its own switch.** Column indexes, expression indexes and persistence each went in behind their own flag, off by default. Shipping them separately meant a problem in one never forced us to turn off the others.
- **Build the debugging tools early.** By December I could dump the index metadata and write an executor's index to object storage on demand. When someone asks "why didn't this query prune?", being able to look at the index beats guessing.

By the end of the year the engine had indexes that it built itself, that survived restarts, and that we trusted. Around the same time a very different kind of column was arriving: vectors. That's [vectors inside a SQL engine](https://sriv.github.io/notes/vectors-inside-a-sql-engine/).
