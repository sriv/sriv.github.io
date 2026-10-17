---
layout: page
title: About
permalink: /about/
---
I'm Srikanth. I work on OLAP query engines at [e6data](https://www.e6data.com). Some of that is the part of an engine that decides how little work a query can get away with: indexes built from the queries themselves, vector search inside SQL, and the Iceberg metadata layer underneath it all. The rest is about where that work actually runs: distribution and workload management.

Lately I've been looking at how agents use OLAP engines. Agents query differently from people and dashboards, and I'm working on what it takes to get an engine ready for that, both in the interface it offers and in the infrastructure it requires.

Most of what I care about comes down to a few beliefs:

- The fastest row is the one you never read. Pruning, indexing and good metadata usually beat a faster operator.
- An engine is only as good as its worst commit path. Table formats are now a performance problem, not just a storage one.
- Measure before you argue. Most of the arguments I've lost, I lost to a benchmark.

Before data infrastructure I spent a long stretch on developer tooling. From 2015 to 2021 I was the lead developer of [Gauge](https://gauge.org), the open-source test automation framework sponsored by ThoughtWorks, and I've carried on as an open-source maintainer in my individual capacity since. That's where I learnt to care about the people on the other end of an API.

The [notes](/) are write-ups of the engine work, in order, with the decisions and the mistakes left in.

Elsewhere: [GitHub](https://github.com/sriv) and [LinkedIn](https://www.linkedin.com/in/srikanth-v-6393b922/).

