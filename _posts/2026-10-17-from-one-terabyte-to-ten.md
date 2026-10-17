---
layout: post
title: "From one terabyte to ten"
redirect_from: /journal/from-one-terabyte-to-ten/
tags: [distributed]
chapter: 13
period: "16 October 2026"
dek: "A distributed query engine that works at one terabyte has proved very little about ten. The lessons from this autumn, minus the numbers."
---

This autumn I went back to distributed execution, this time on the Rust engine, with a simple-sounding goal: take a set of analytical queries that run well on one big machine and make them complete and stay fast when the data grows tenfold and the work spreads across many machines.

I'm not going to share numbers here. But the lessons don't need them, and most of them are things I wish someone had told me at the start.

## Write the goals down, and make them per query

The first useful thing we did was agree on what "working" means, in writing, before any more runs:

- **Every query completes.** Not most of them. A query that fails at ten terabytes is a bug, not a statistic.
- **No query gets slower because distribution exists.** That applies to queries that distribute *and* to queries that don't. On a cluster of smaller machines, a query that stays on one node is running on a fraction of the hardware it had before, so "leave it alone" isn't neutral. It's a regression.
- **Never change the single-node plan to help the distributed one.** Anything that only matters when distributing has to be decided inside the distributed path.

The second rule is the one that changed how we looked at results. A total runtime can improve while a dozen individual queries get several times slower. Totals are for slides. Per-query comparisons against a single-node baseline are for engineering.

## The coordinator is your serial fraction

The easy way to distribute a single-node engine is to split the scans across workers and pull everything above them back to one coordinating node. It works well at first, because scans are where most of the time goes on small data.

It stops working as the data grows, and Amdahl's law tells you exactly why. Whatever still runs on the coordinator (joins, final aggregations, window functions, anything over a materialised intermediate result) is the serial part of the job. Add machines and the parallel part shrinks, but the coordinator's time doesn't, so its share grows until it is most of the runtime. And when that work grows with the input, ten times the data makes the serial part ten times bigger as well.

The measure that taught me the most was simply: **what fraction of each query's time is spent on the coordinator?** A rule I'd now give any team: coordinator work should be proportional to the size of the *result*, not the size of the *input*. Any operator that breaks that rule doesn't belong on the coordinator. It's next on the list to distribute.

{% include diagrams/coordinator-share.svg %}

## Spill is not a distribution strategy

When queries run out of memory at ten terabytes, turning on spill-to-disk is tempting. It looks like it should make the failures go away. When we tried it across the whole query set, the result was worse, not better: more queries failed rather than fewer, and some that used to be fast got several times slower.

The better answer is almost always to spread the working set. A large intermediate result that doesn't fit on one machine often fits comfortably across four. Spill, and materialising intermediate results to storage, are last resorts for when there's genuinely nowhere left to put the data, not a substitute for distributing the work.

## Understand before you run

A full run at this scale ties up a fleet of large machines for a long time. Early on we fell into a loop: guess a cause, change something, run again, see no difference, guess again. After the third run in a row that didn't move anything, I started calling it rock, paper, scissors, and we stopped.

What replaced it:

- **Stop guessing and explain the slowdown from the data you already have.** Split each query's wall time into coordinator work, worker compute, time waiting on exchanges, and idle time. The answer was usually already sitting in the output of the last run.
- **One run per mechanism, with the prediction written first.** If you can't say what number should move and by roughly how much, you don't understand it yet.
- **Never change two things in one run.** We once changed a setting and the set of queries in the same run, and the result couldn't be compared to anything.

## Reproduce big problems on a small machine

Most of the debugging happened on a laptop, not in the cloud. The trick is that you don't need ten terabytes to reproduce a ten-terabyte failure. You need the same *pressure*. Run a smaller dataset across several local workers and squeeze each worker's memory until the same queries fail in the same places. The failure shapes carry over remarkably well.

Two cautions from doing this:

- **Collect statistics first.** Without table statistics, the planner falls back to heuristics, often little better than the order the query was written in, and you end up measuring the planner instead of the engine.
- **Keep a correctness oracle.** Every distributed run gets compared against a single-node run of the same queries, as unordered rows with a tolerance for floating point, of the same queries. A distributed engine that's fast and occasionally wrong is worse than useless.

## Bugs that need two machines

Some bugs don't exist until there's more than one node. Two kinds caught me out:

- **A reader that stops reading can block every writer.** An inner hash join with an empty build side can reasonably decide not to read its probe input at all, and a `LIMIT` that has seen enough rows can stop reading the rest. In one process that's a free shortcut. In a distributed plan, that input is often an exchange, and its writers on other machines sit waiting for reads that will never come. Every consumer of an exchange has to either drain it or say clearly that it's done.
- **Shared flow control hides in the transport.** Many logical streams multiplexed over one connection share that connection's flow-control window. If enough of them stall, all of them stall. That bug appeared only with two or more nodes and disappeared when buffers were made huge, which is exactly the pattern to look for.

The general lesson is to make hangs talk. A warning that says "this exchange has been stalled for five seconds, and here's who is waiting on whom" turns a frozen query into a bug report.

## A green run that didn't distribute

The most expensive mistake of the autumn wasn't in the engine. A missing setting meant the workers never registered as members of the cluster, so nothing distributed. Every query still ran on the coordinator and passed, slowly. We ran several large benchmarks before noticing that we'd been measuring a single-node engine on a multi-node bill.

In the same vein, a per-node agent added to every machine in the cluster quietly took up a little memory. That was enough for our executor's memory request to stop fitting, and the setup step reported it as a capacity problem.

Both teach the same lesson: **record the decision, not just the outcome.** Each query now records whether it distributed, how, and if not, why not. Each run checks that its machines are the ones it asked for. A result from a setup you haven't checked is just a number.

## Scale shows you which plans were only lucky

The last lesson is about the planner. At one terabyte, a few queries were planned badly and nobody noticed, because a bad plan over modest data still finishes. At ten terabytes the same plan never finishes. One query with join keys buried inside `OR` branches got a nested-loop join, which was a minor slowdown at small scale and impossible at large scale.

Scaling up is the most reliable bug-finder you have for the planner. Anything quadratic is waiting for you there.

## Where we're taking it

All of the above is ground any team will cover when they distribute a single-node engine, and none of it depends on how we do things at [e6data](https://www.e6data.com/). Workload management, deciding what runs where and alongside what, is the part we've deliberately kept as our own, and it's where we've taken a different road. That deserves its own write-up when it's ready.

## What I'd tell a team about to scale up

- **Agree on per-query goals before you run anything big.** Including the queries you don't distribute.
- **Track the coordinator's share.** It's the number that tells you whether adding machines can help.
- **Distribute before you spill.**
- **Explain, predict, then run.** One mechanism per run, with the expected result written down first.
- **Reproduce at small scale under memory pressure, with statistics and an oracle.**
- **Record every distribution decision, and check the setup of every run.** A run that passes without distributing will happen to you.
