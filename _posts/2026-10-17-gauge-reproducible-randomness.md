---
layout: post
title: "Random order is only useful if you can replay it"
tags: [gauge, testing, cli design]
when: 2025-11-06
period: "6 November 2025"
dek: "In 2017 I removed a flag that ran Gauge specs in random order. In 2025 I added it back. The difference was a seed, and a place to keep it."
---

On 6 November 2025 I merged a [change to Gauge](https://github.com/getgauge/gauge/pull/2794) that lets you run specs and scenarios in random order:

```
gauge run --sort=random specs/
Randomizing execution with seed: 1761802692487777000
```

Eight years earlier I had [removed a flag that did much the same thing](https://github.com/getgauge/gauge/pull/664). This note is about why the first version went and what made the second one worth having.

## Why run tests in random order at all

A suite that always runs in the same order can hide dependencies between tests. Scenario B passes because scenario A happened to leave a row in the database, or a file on disk, or a logged-in session. Nothing in either scenario says so. You find out the day someone runs B on its own, or the day the order changes for an unrelated reason.

Gauge has always said execution order isn't guaranteed unless you ask for `--sort`. In practice, specs ran in the order they were found, and scenarios ran in the order they were written. That makes the order a consequence of the implementation, not a promise, and people come to rely on consequences. Shuffling the order on purpose is the cheapest way to find out whether a suite has that kind of hidden coupling.

## The first attempt, and why I removed it

In May 2017 we [proposed](https://github.com/getgauge/gauge/issues/641) an `--order` flag with two values, `sort` and `random`, to replace the existing `--sort`. It made it into nightly builds but never into a release. On 1 June 2017, a few weeks after the proposal, I removed it again.

The reasons I gave at the time were mostly about confusion. There were now two flags that touched ordering. It wasn't clear what `--order=sort` meant when specs were split across parallel streams. And there was a philosophical worry that a built-in ordering option would encourage people to write specs that depend on each other.

Looking back, the real gap was a different one, and it took a later discussion to make it obvious.

## What random order needs

In October 2025 a contributor [asked for random order again](https://github.com/getgauge/gauge/issues/2793), for the reason above: to expose hidden dependencies in an API test suite. My first reply was a list of objections, and the main one was this: if a run fails because of the order, how do you debug it? The next run will choose a different order and probably pass. You can't tell an ordering bug from ordinary flakiness, and you can't reproduce either.

Chad Wilson, another maintainer, pointed out that this is a solved problem. Tools that shuffle tests print the seed they used, and accept a seed as input, so that any run can be replayed exactly. JUnit and the Gradle test-partitioning plugins work like this. As Chad put it, you shouldn't implement random ordering without doing this.

He was right, and it changes the trade-off completely. A random order you can't replay is noise. A random order you can replay is a search: each run tries a new arrangement, and when one fails you have its address.

## What I built

The change is small. Most of it is flags and tests.

- `--sort` now takes a value: `alpha` or `random`. A bare `--sort` still means alphabetical, so existing scripts keep working.
- With `random`, Gauge seeds a pseudo-random generator, shuffles the specs, and then shuffles the scenarios within each spec. Table-driven scenarios are shuffled too, because the shuffle runs after tables have been expanded into scenarios.
- The seed is always printed. If you don't pass one, Gauge generates one from the clock and prints that.
- `--random-seed=<n>` replays a specific order.

The part that took the most thought was making `--repeat` and `--failed` work. Gauge already saves the arguments of the last run in `.gauge/lastRunCmd.json`, so that `gauge run --repeat` can rerun it. If the seed were generated inside the run, it would be lost, and `--repeat` would shuffle again. So the seed is generated before the arguments are saved, and added to them as an explicit `--random-seed`. A repeated run is then just a run with a seed, and nothing else needs to know about randomness.

## What a seed does and doesn't promise

A seed reproduces an order only for the same input. Gauge shuffles the list of specs it was given, so the same seed over the same specs gives the same order. Add a spec, remove one, or rerun only the failed ones, and the same seed still gives a deterministic order, but a different one.

For `--failed` that's the behaviour you want: you rerun a smaller set, in a fixed order, and can rerun it again. But it's worth saying plainly, because "uses the same seed" is easy to read as "uses the same order".

There's a second, smaller gap. The seed is printed in the console output and saved with the last run, but it doesn't appear in the HTML, JSON or XML reports. The contributor who asked for the feature raised this straight away. Chad's answer was that the seed on its own isn't enough to reproduce a run: you also need the other arguments, and those don't reach the report plugins today. That's still open.

## What I'd check in any runner

- **Randomness in a tool needs an address.** Any time a tool makes a random choice that affects the result, print what it used and accept it back as input. Otherwise it's adding noise to the thing people are trying to debug.
- **Save the generated value, not the instruction to generate one.** "Shuffle" isn't reproducible. "Shuffle with 1761802692487777000" is.
- **Revisit removals when the objection changes.** I removed `--order` in 2017 for reasons that were partly about naming and partly about not knowing how to make a failure reproducible. With the second problem solved, the first was a matter of choosing flag values carefully.
- **Keep the old meaning of a flag.** Turning `--sort` from a boolean into a value without breaking a bare `--sort` cost one line of flag configuration and saved every existing CI script.

The feature itself is a few dozen lines. Most of the value came from the discussion that went before it, and from someone pointing out that the problem I was worried about already had a standard answer.
