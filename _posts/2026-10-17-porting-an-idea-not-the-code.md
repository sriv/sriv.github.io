---
layout: post
title: "Porting an idea, not the code"
redirect_from: /journal/porting-an-idea-not-the-code/
tags: [rust, datafusion, indexes]
chapter: 9
period: "18 December 2025"
dek: "Bringing dynamic indexes from a Java engine to one built on Rust and DataFusion. What carried over was a handful of rules. Almost none of the code did."
---

By the end of 2025 the team was building a native executor in Rust on top of [Apache DataFusion](https://datafusion.apache.org/). I'd spent a good part of the previous year on dynamic indexes in our Java engine ([the post on lazily built indexes](/notes/let-the-queries-build-the-index/)), so in December I took on bringing them across.

I expected a translation job and got something closer to a redesign. Writing an idea a second time, in a different engine, shows you which parts of it were the idea and which parts were just how the first engine happened to be built.

## What carried over

Here's what survived the trip unchanged. None of it is code:

- **An index answers "maybe" or "no", and a wrong "no" is the only real bug.** Missing entries, failed builds and anything unexpected all mean "maybe".
- **Build lazily, from data the query was reading anyway.** No background jobs, no separate build step.
- **Key everything by file and row group.** Files in a table format don't change once written, so an entry for a given file stays true.
- **An index built from a partial view of the data must never be kept.** This was the rule that mattered most in Rust, for reasons below.

Everything else was rewritten from scratch, and it should have been. The Java implementation was shaped around the Java engine's scan operator, its threading and its caches. Translating it line by line would have brought all of that along into an engine that works differently.

## Use the host's extension points

DataFusion is built to be extended, and the most useful decision in the port was to lean on that instead of fighting it.

DataFusion already knows how to prune Parquet row groups. Given a query's filter, it builds a **pruning predicate**, then asks a statistics provider for the min, max and null counts of each row group and works out which row groups can't possibly match. The provider is an interface. DataFusion ships one that reads the Parquet footer, but nothing stops you from supplying your own.

So the dynamic index became exactly that: a statistics provider backed by our index store. Our code answers "what's the min and max of this column in row group 3 of this file?", or "I don't know", and DataFusion's existing logic does the rest: `AND`, `OR`, `IN`, ranges, negation, all of it. In the Java engine I'd written and tested that predicate logic myself. Here I got it for free, along with everyone else's bug fixes.

The other half was the scan itself. Rather than fork DataFusion's Parquet source, I wrapped it: our source holds the stock one and passes every call through, except opening a file, where it narrows the list of row groups to read before handing over. My first cut copied more of the stock source than it needed to. The rewrite later that day was mostly deleting those copies and passing calls through.

{% include diagrams/datafusion-ladder.svg %}

The order of the checks matters. Our index lives in memory, so it goes first. The footer statistics come next, since the footer has already been read. Parquet's own bloom filters are last, because checking them means fetching more bytes. Each check only sees the row groups the cheaper ones before it let through.

## The filter that moved

This is where the port taught me something about the original.

In the Java engine, the scan decoded a row group into batches and a separate filter operator dropped rows afterwards. Whatever the scan produced was the whole row group. Building an index from it was safe almost by accident, because nothing upstream had thrown rows away.

DataFusion can push filters down into the Parquet reader itself, so rows that don't match are dropped *while* decoding. That's a real performance win, and you want it on. It also means the batches that come out of the scan are no longer the row group. They're the part of the row group the current query cared about. Build a min/max or a bloom filter from that, and you've built an index that will confidently say "no" to values that are sitting right there in the file.

In Java this rule had been met by the shape of the engine. In Rust it had to be enforced deliberately: an index is only kept when we know it was built from the whole row group, and anything less is discarded. I won't go into the mechanism here. The important part is being able to name the rule. Once you can say "never keep an index built from a partial view", a whole class of bugs becomes something you check for rather than something you stumble into.

## A simpler bloom filter

The first Rust version fed values into a bloom filter with a separate branch for each column type, and only covered a handful of types. In January I replaced it with a simpler design: hash every value to a 64-bit number first, whatever its type, and keep a bloom filter of those hashes.

That one change removed a surprising amount of code:

- **No type-specific logic.** Integers, strings, dates and decimals all go through the same filter once they're hashed.
- **Uniform size.** Every filter for a given expected row count is the same size, which makes memory accounting predictable.
- **Mergeable.** Two filters of the same size combine with a bitwise OR, so filters built in pieces can be joined without going back to the data.

The one thing to be careful of is that the hash has to be stable and has to agree between the side that builds the filter and the side that probes it. Hash `5` as an `INT` when you build the filter, probe it with the `BIGINT` literal the query planner produced, and you get a wrong "no". It's the same bug from [the bloom filter post](/notes/bloom-filters-at-the-scan/) in different clothes.

## What I'd tell someone porting a subsystem

- **Write down the rules before you write any code.** The list above came from asking "what would make this wrong?", not from reading the old code.
- **Look for the rules the old system enforced by accident.** They're the ones a new engine breaks quietly.
- **Prefer the host's extension points to a fork.** You inherit its correctness and its future fixes, and your own code gets smaller.
- **Expect the second version to be simpler.** If it isn't, you may be porting the first engine's shape rather than the idea.
