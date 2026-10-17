---
layout: post
title: "Spot instances and the query that must not die"
chapter: 8
period: "5 October 2025"
dek: "Spot capacity is the cheapest compute a cloud will sell you, and it comes with a short warning before it's taken back. Deciding where in the stack to absorb that warning was the interesting part."
---

By the second half of 2025 spot instances were one of the bigger levers we had on cost: spare cloud capacity sold at a deep discount, on the understanding that the provider can take it back. AWS gives you a two-minute warning. Azure and GCP give you closer to thirty seconds. Then the machine is gone.

For a stateless web service that's an annoyance. For a distributed query engine it's a real problem. An executor that disappears mid-query takes with it the tasks it was running, any intermediate results it was holding, and, if it happened to be coordinating the query, the query itself.

In September and October 2025 I worked on making the engine survive that. The code was the easy half. The harder half was deciding *where* each kind of failure should be absorbed.

## The decision: where to retry

There are three obvious places to put recovery, and they behave very differently.

**Let the platform restart it.** Kubernetes notices the pod is gone and schedules a new one. This is free and it's what everything else in the cluster already does. But a new pod knows nothing about the query that was running. Restarting the executor doesn't restart the work.

**Retry the tasks.** The queue that hands out work knows which tasks went to which executor. If an executor dies, its unfinished tasks can be handed to someone else. The query keeps running and only the lost slice is redone.

**Retry the query.** Throw the whole query away and run it again from the top. Simple and always correct, but it can turn a short interruption into a much longer query.

The answer we landed on was all three, each at the level where it's cheapest, plus a fourth step that comes before any of them: use the warning.

{% include diagrams/spot-timeline.svg %}

## First, use the warning

Even thirty seconds is a long time for an executor, and two minutes is a lot. Most scan tasks finish in seconds. So the first thing each executor got was a small detector per cloud that watches for the interruption notice: the instance metadata endpoint on AWS, scheduled events on Azure, the preemption signal on GCP.

When the notice arrives, the executor starts **draining**:

- it stops asking the queue for new tasks,
- it keeps working on the tasks it already has,
- it tells the queue it's terminating, so the queue stops routing work to it and can start moving anything that won't finish in time.

When it works, the interruption ends right there. The tasks in flight finish inside the window, nothing new lands on the machine, and the query never notices. The best retry is the one you don't need.

## Then, retry the tasks

When the machine goes before its work is done, the queue has to tell the difference between three states: alive, terminating (we were warned), and dead. "Dead" means it isn't answering *and* it never said it was leaving. That's the case where its incomplete tasks get retried elsewhere, for every query it was taking part in.

The retry is deliberately best-effort. Some work can't simply be replayed. If the machine was holding part of a join's hash table, or shuffle output that other tasks were waiting to read, that state is gone with it, and redoing one task doesn't bring it back. When a task-level retry can't put things right, the failure moves up a level instead of being papered over.

## Last, retry the query

The coordinator is the special case. It holds the query's plan, tracks which stages are done, and assembles the result. If the coordinating executor dies, there's nobody left in the cluster who knows what the query was doing. So that case goes all the way up: the planner, which still has the original query, retries it from the top on a healthy executor.

It's the most expensive recovery and the rarest, and that's the right way round.

## Stop calling the dead

The part that needed the most care wasn't the retry logic. It was everything *around* a dead executor. Once a machine is gone, every other component that still has its address keeps trying to talk to it: status checks, result fetches, cleanup calls. Each one waits for a timeout. Multiply that by every query and every component, and a single lost executor slows the whole cluster down for minutes.

So executors got a **circuit breaker**. After a call to a dead or terminating executor fails, the circuit for that address opens and later calls fail immediately instead of waiting. We split calls into two kinds:

- **critical** calls, where the caller needs the answer, fail fast with a clear error, so the retry logic above can take over,
- **non-critical** calls, like a status poll or a cleanup, quietly return nothing.

That split mattered more than the breaker itself. The first version was strict about everything, and within days we made it more forgiving, letting the non-critical calls degrade gracefully instead of failing.

One more lesson from this stretch: failure handling has a way of calling itself. We had a recovery callback that, a couple of hops later, ended up triggering itself, and it only showed up during real interruptions. If your recovery path can trigger itself, it eventually will.

## What I'd tell a team running on spot

- **Use the warning before you build the retry.** Draining handles more interruptions than any retry does, and it's much simpler.
- **Recover at the lowest level that has enough state.** Tasks for workers, queries for coordinators, and the platform only for the process itself.
- **Make "terminating" a real state.** Being able to tell "warned and leaving" from "gone without a word" is what makes the rest of the logic sane.
- **Break the circuit, and decide which calls are allowed to fail quietly.** A dead machine shouldn't cost every other component a timeout.
- **Test with real interruptions.** Simulated notices are useful, but the cloud's timing is never quite what you mocked. Run it on real spot capacity before you trust it.
