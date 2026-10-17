---
layout: post
title: "Manifests are data too"
redirect_from: /journal/manifests-are-data-too/
chapter: 10
period: "13 May 2026"
dek: "Iceberg's metadata files have always been row-oriented Avro. Version 4 makes them Parquet. Everything I'd learned about not reading data turned out to apply to metadata as well."
---

This year I moved down a layer. After two years inside query engines, deciding what not to read, I started working on the table format underneath them: [Apache Iceberg](https://iceberg.apache.org/), and specifically the metadata changes going into version 4 of its spec.

The first piece I implemented was the smallest-sounding one: writing **manifests** as Parquet instead of Avro. At the time it was a proposal under discussion upstream. It has since landed in the v4 spec. This post is about why such a dull-sounding change matters, and why it helped commits as well as queries.

## What a manifest is, and who reads it

An Iceberg manifest is a list of files. Each entry describes one data file: its path, partition values, row count, and statistics for its columns: lower and upper bounds, null counts and so on.

Two kinds of readers open manifests:

- **Query planning** reads them to decide which data files a query needs, using the partition values and column bounds. This is the pruning ladder from [the first post](/notes/the-cheapest-row-is-the-one-you-never-read/), one level up.
- **Commits** read them too, which is easy to forget. A compaction has to confirm the files it's replacing are still in the table. A retried commit has to look at what changed underneath it. A snapshot summary needs counts.

In versions 1 to 3, a manifest is an Avro file, which stores data row by row. To get any field of an entry, you decode the whole entry.

## Where Avro hurts

The column statistics are where it shows. In v1–v3 each entry stores them as maps from column ID to a value: one map for lower bounds, one for upper bounds, more for null counts, value counts and sizes. The bounds are stored as bytes, which the reader then has to decode according to each column's type.

Picture a wide table with a few hundred columns and a query that filters on one of them. Every manifest entry carries bound maps for all of those columns, and planning decodes all of it to find the one pair of bounds it needs. Most of the bytes read during planning belong to columns the query never mentions.

That's exactly the problem the first post here was about, just in metadata instead of data. And the fix is the same one.

## Parquet manifests

In v4, manifests are Parquet files. The statistics change shape too. Instead of maps of bytes, each table column gets its own typed struct inside a `content_stats` field. A column's bounds are stored as that column's real type, so an `int` column has `int` bounds.

Each stats struct gets a fixed block of 200 field IDs, worked out from the table column's own ID: `10_000 + 200 × field-id`. That leaves room for every metric a column can have, including nested ones like geospatial bounds. A reader that wants the bounds for column 2 knows exactly which Parquet columns hold them, without looking at anything else.

{% include diagrams/manifest-columns.svg %}

That buys three things:

- **Projection.** Planning reads only the stats columns for the columns in the filter, plus the path. The rest of the manifest stays on disk.
- **No byte decoding.** Bounds come out as typed values, already in the right representation.
- **Pruning inside metadata.** A Parquet manifest has its own row-group statistics. A large manifest can skip whole chunks of its entries before decoding them, using the same min/max machinery we use on data.

## Why commits got cheaper

The query-side win is the obvious one. The commit-side win surprised me more.

Most of what a commit reads from existing manifests is narrow. Validating a compaction mostly needs paths and statuses. Rebasing a retry needs to know which entries changed. Updating summary counts needs record counts. With Avro, each of those still decoded whole entries, statistics maps included. With Parquet, each reads the one or two columns it needs.

Writing got better too. Manifest columns are very repetitive (long, similar file paths, the same partition values, similar row counts), and columnar compression handles that well. Smaller manifests are cheaper to write, upload and read back on the next commit.

A commit is a chain of small reads and writes against object storage, and every one of them sits inside the window where another writer can beat you to it. Making each step touch fewer bytes makes the window shorter, and a shorter window means fewer retries.

## What it costs

Parquet isn't free, and it's worth being honest about where it loses:

- **Tiny files pay a fixed tax.** A Parquet file has a footer, a schema and per-column overhead. A manifest with three entries can come out bigger in Parquet than in Avro.
- **The schema depends on the table.** Because `content_stats` has one struct per table column, the manifest schema is built from the table schema. Schema evolution has to be handled carefully, which is why the spec says stats are resolved by ID and names are informational only.
- **Readers have to change.** Every engine that reads manifests needs a Parquet path. While the proposal was still being discussed, we kept the new format behind a switch, so tables could be moved over deliberately rather than all at once.

## What I'd tell someone implementing it

- **Treat metadata as data.** Everything you know about columnar layout, projection and pruning applies. It's easy to forget, because metadata files feel small, until a table has millions of them.
- **Look at the commit path, not just planning.** The reads a commit does are narrow and frequent, and they're exactly the kind columnar formats are good at.
- **Round-trip every type.** Bounds for floats (where `NaN` has no place in the ordering and `-0.0` and `+0.0` compare equal but aren't the same bits), decimals, timestamps and strings all have edge cases. A test that writes and reads back every type is cheap, and it's worth writing before anything else.
- **Build ahead of a spec behind a switch.** Implementing a proposal early teaches you a lot, but the format will change before it's final, and you don't want existing tables quietly committed to your first guess.
