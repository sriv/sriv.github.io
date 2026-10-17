# Benchmarks you can't trust, used for the one thing they're good at

By Srikanth Venugopalan, 14 July 2020. Topics: gauge, testing, ci.
Canonical: https://sriv.github.io/notes/gauge-benchmarks-in-ci/

> Shared CI machines are terrible benchmark hardware. I put benchmarks on every Gauge pull request anyway, because the question wasn't how fast Gauge is but whether this change made it slower.

Through the first half of 2020 I was changing how Gauge ran things in parallel: one multithreaded runner instead of a process per stream, runners started up front, suite hooks run once. Every one of those changes could make a run faster or slower, and I had no record of which. Beyond "it felt about the same on my laptop", there was nothing to check against.

So in June 2020 I started [gauge-benchmarks](https://github.com/getgauge/gauge-benchmarks), and in July wired it into [Gauge's pull request](https://github.com/getgauge/gauge/pull/1682) and [merge](https://github.com/getgauge/gauge/pull/1686) workflows.

## Deliberately boring

The harness is a handful of shell scripts and three seed projects: a plain Java project, the same thing under Maven, and the same under Gradle. Each project's `run.sh` runs `gauge run specs` under `/usr/bin/time` and appends one line to a CSV: the Gauge commit, CPU percentage, peak memory, wall time and exit code.

Every project runs three ways, because those were the paths I was changing:

| Mode | What it exercises |
|---|---|
| serial | one runner, one stream |
| parallel | one runner process per stream |
| multithreaded | one runner, streams on threads |

That's 3 projects × 3 modes = 9 jobs, run as a matrix in GitHub Actions. No profiler, no microbenchmarks, no statistics library. I wanted something anyone on the project could read in five minutes and fix without asking me.

The exit code column earns its place. A run that's twice as fast because it crashed halfway is not an improvement, and a benchmark that doesn't record success will eventually report one.

## The machines lie, so compare on the same machine

GitHub's hosted runners are shared, virtualised and noisy. An absolute number from one of them says almost nothing. The note that the bot posts under every result says so in as many words: these are indicative numbers, they make sense for comparison, don't take them as actual benchmarks.

What they're good for is a coarse before-and-after. On a pull request, the jobs build Gauge from the branch, run all nine combinations, and post a table that puts the branch's numbers next to the last few rows recorded from master. Noise of a few percent washes out. A change that doubles memory or adds seconds to a fourteen-second run doesn't.

On merge to master the same jobs run again and append their rows to the CSVs in the benchmarks repo, which also backs a small chart page. That history is the part I'd keep if I could only keep one: a regression found three weeks late is still findable when every commit has a row.

## The comment that a pull request couldn't post

The fiddly part wasn't benchmarking. It was getting the result back onto the pull request.

Most contributions to an open-source project come from forks, and GitHub Actions, sensibly, gives a workflow running on a fork's pull request a read-only token. It can run the benchmark, but it can't post the result back as a comment. In mid-2020 there was no event-driven way around that.

So I wrote a small action, [artifact_as_comment](https://github.com/getgauge-contrib/artifact_as_comment), and its own README calls the approach roundabout. The pull request job writes its results to a markdown file and uploads it as a build artifact. A separate workflow in the main repository, which does have write access, runs on a schedule every fifteen minutes, looks at open pull requests and their latest runs, and if it finds a matching artifact, posts its contents as a comment. Credit to [nyurik](https://github.com/nyurik/auto_pr_comments_from_forks), whose repository convinced me there wasn't a cleaner route at the time; I did the same thing in JavaScript to skip the Docker startup.

Polling is ugly. It was also the only design that kept untrusted fork code away from a write token, which is the property that matters.

## Six years on

The merge job is still running as I write this in October 2026, still appending a row for each commit to Gauge's master. Haroon later moved the seed projects to Java 11 and current dependencies, and dependabot keeps the build tools fresh. I haven't touched it in years. That's the best thing I can say about it.

What I'd take from it:

- **On noisy hardware, measure differences, not values.** Shared CI can't tell you how fast something is. It can tell you that this commit is a lot slower than the last one, if both ran there.
- **Keep the history.** A per-commit row turns "when did this get slow?" from archaeology into a lookup.
- **Record whether the run succeeded.** A benchmark without an exit code will one day celebrate a crash.
- **Build it so it outlives your attention.** Shell, CSV and a cron job are not impressive. They are why it still works.
