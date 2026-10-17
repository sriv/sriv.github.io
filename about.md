---
layout: default
title: About
permalink: /about/
---
<div class="prose about">

# About

I'm Srikanth. I work on the query engine at [e6data](https://www.e6data.com), where I've spent the last couple of years on the parts of an engine that decide how little work a query can get away with: indexes built from the queries themselves, vector search inside SQL, execution that spans more than one cloud, and lately the Iceberg metadata layer underneath all of it.

Most of what I care about comes down to a few beliefs:

- The fastest row is the one you never read. Pruning, indexing and good metadata usually beat a faster operator.
- An engine is only as good as its worst commit path. Table formats are now a performance problem, not just a storage one.
- Measure before you argue. Most of the arguments I've lost, I lost to a benchmark.

Before data infrastructure I spent a long stretch on developer tooling, including a few years as a maintainer of [Gauge](https://gauge.org), the open-source test automation framework from ThoughtWorks. That's where I learnt to care about the people on the other end of an API.

The [journal](/) is where I write up what I've worked on, in order, with the decisions and the mistakes left in.

Elsewhere: [GitHub](https://github.com/sriv) and [LinkedIn](https://www.linkedin.com/in/srikanth-v-6393b922/).

</div>
