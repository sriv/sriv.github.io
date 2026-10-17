---
layout: post
title: "Once per suite means once per process, until it doesn't"
tags: [gauge, testing, concurrency]
when: 2020-05-14
period: "14 May 2020"
dek: "Gauge's BeforeSuite hook ran once per parallel stream, not once per run. The fix was a few hundred lines. The decision behind it was that every language runner had to support threads."
---

Gauge, the test automation tool I worked on for several years, has a hook called `BeforeSuite`. You put things in it that should happen once: start a browser grid, seed a database, open a connection pool. Its partner, `AfterSuite`, tears them down.

In September 2019 someone filed [an issue against the Java runner](https://github.com/getgauge/gauge-java/issues/297) that was short and completely correct: when you run specs in parallel, `@BeforeSuite` and `@AfterSuite` run once for each parallel stream. Run with four streams and your database gets seeded four times, torn down four times, and probably raced in between.

## Why it happened

Gauge's core is a Go binary. The step implementations live in a separate process, a *language runner*, one per language: Java, C#, JavaScript, Python, Ruby. The core parses specs, decides what to run, and sends the runner messages like "execution starting", "run this step", "execution ending". The runner's job on "execution starting" is to call your `BeforeSuite` methods.

The original parallel execution was the simplest thing that works. Split the specs into N groups, start N runner processes, and drive each one as if it were a serial run. Each runner received its own "execution starting", so each one ran the suite hooks. From the runner's point of view it was doing exactly what it was told. "Once per suite" had quietly meant "once per process", and parallelism had made those two different things.

You can't fix that inside a runner. Four processes don't know about each other, and making them coordinate (a lock file, a leader election, a shared flag in some external store) would move a test tool's problem onto the user's machine in a fragile way.

## The threads were already there

The way out had been built years earlier for a different reason. In 2016 a user [reported Gauge crashing](https://github.com/getgauge/gauge/issues/492) at 50 parallel streams: 50 JVMs on a two-core box ran out of native threads before any test started. Process-per-stream gets expensive fast when every process is a full JVM.

The answer then was a multithreaded mode. The core starts one runner and tells it how many streams to use, and the runner runs streams on threads inside one process. I wrote the first cut of that in the Java runner in September 2016, and Kashish and Apoorva did the work in the core to drive it. It shipped behind a setting, `enable_multithreading`, and for years it was the option you reached for when process-per-stream got too heavy.

Once there's a single runner process, "once per suite" has an obvious home again. That's what [the change in May 2020](https://github.com/getgauge/gauge/pull/1644) did. When the runner talks to the core over gRPC and says it supports multithreading, the core now:

1. starts one runner and initialises the suite's data store once,
2. sends "execution starting" once, so `BeforeSuite` runs once,
3. starts each stream as a goroutine that sends its specs to that same runner, tagged with a stream number,
4. waits for every stream to finish,
5. sends "execution ending" once, so `AfterSuite` runs once, then stops the runner.

Getting `AfterSuite` into the right place took a second attempt; the order is the whole point, so I added tests that check the order hooks fire in, because that's the property users actually depend on. The same pull request also stopped the core starting a runner for validation and then another for execution, and started the runners for the remaining streams up front instead of lazily. The Java side was [a matching change](https://github.com/getgauge/gauge-java/pull/442) in the runner.

## The decision, not the diff

The part I'd point to is in the description of that pull request, because it isn't code. A runner that doesn't support multithreading still gets one process per stream, and in that mode each process still runs the suite hooks. I couldn't fix that without the coordination machinery I didn't want. So the honest position was:

> This brings us to the decision that all runners should support multithreading/multitasking in order to get the Suite Hooks to run as expected.

That's a statement about the plugin contract, not about one runner. It meant the Java, C# and other runners had real work to do: shared state between streams had to become thread-safe, anything stored at suite level was now shared by every stream, and any step code that assumed it owned the process was now wrong. Some of that work landed in users' own step implementations, which is the uncomfortable part. A hook that used to run in isolation now runs once while other streams wait on it.

The alternative was to keep pretending process-per-stream gave you suite semantics. It didn't, and the bug report proved users had noticed.

## What "once" should mean

- **Name the unit a hook is scoped to.** "Suite" sounded unambiguous until parallelism split one suite across processes. If a hook is "once per X", X has to be something the system can actually see.
- **Lifecycle belongs to whoever sees the whole run.** The core saw every stream; no runner did. Moving "start" and "end" to the core, and making runners pure executors in between, fixed the semantics without any cross-process coordination.
- **Some fixes are contract changes.** The code fixed the threaded path. The pull request description is what told every runner maintainer, and every user writing hooks, what was now expected of them. Writing that down plainly mattered as much as the diff.
