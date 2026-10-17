# Shipping a risky language feature behind a flag, and what the flag cost

By Srikanth Venugopalan, 28 September 2018. Topics: gauge, open-source, design.
Canonical: https://sriv.github.io/notes/gauge-a-risky-feature-behind-a-flag/

> Table-driven scenarios went into Gauge behind an experimental flag in 2018. The flag did its job: it let the core ship while everything around it caught up. It also stayed for seven years, and that part was not the plan.

Gauge specs are Markdown. A spec can carry a data table, and since 2017 Gauge could run a whole spec once per row of that table, thanks to [work](https://github.com/getgauge/gauge/pull/600) by a teammate that also taught it to [run those rows in parallel](https://github.com/getgauge/gauge/pull/630). What people kept asking for was the same thing one level down: a table attached to a single scenario, so one scenario could iterate over its own rows without dragging the rest of the spec along. The [request](https://github.com/getgauge/gauge/issues/111) was opened in March 2015. In 2017 a user called it one of the main things stopping them from moving off Cucumber.

On 28 September 2018 I opened [the pull request](https://github.com/getgauge/gauge/pull/1202) that added it. Its description starts with a note I added during review: the feature is experimental, disabled by default, and enabled by setting `allow_scenario_datatable=true`. This note is about why it shipped that way, and what that choice cost later.

## Why this one was risky

Most features in a test runner are additive. A new command, a new flag on an existing command, a new report column. You can add them without changing what an existing spec means.

A scenario table is different, because it changes the language. Before the change, a table inside a scenario was just a table: a step argument, or text. After it, the same Markdown could mean "run this scenario once per row". Steps could now use dynamic parameters like `<word>` that resolve against the scenario's table, the spec's table, or both. That is a change in parsing, in resolution, and in execution, all at once. The diff touched the parser, argument lookup, the spec and scenario executors, the parallel execution path, and the protobuf messages every plugin consumed.

And Gauge was not one binary. The core ran specs, but language runners for Java, C#, Python, Ruby and JavaScript executed the steps, and separate plugins built the HTML, XML and JSON reports. The IDE plugins parsed specs themselves. A language change in the core is only finished when every one of those understands it, and they were separate repositories with their own release cycles.

The pull request's to-do list was honest about this. Execution worked: steps resolved their parameters from the scenario table, a scenario ran once per row, and a scenario that didn't use the table ran once. But the suite result didn't carry the per-row results properly yet, the HTML report didn't know about any of it, and every row's scenario result held its own copy of the whole table, which I flagged as wasteful and in need of a backward-compatible fix.

## What the flag was for

There were two other options. One was to hold the change until the core, the reports and the IDE plugins were all ready, and release them together. In an open-source project with a few maintainers and many repositories, that means the branch rots while you wait. The other was to turn it on for everyone and fix the reports as complaints arrived. Since the feature changes what existing Markdown means, that risked changing the behaviour of specs people had already written.

The flag gave a third path. The parser only treats a table under a scenario as a scenario table when the flag is set. With the flag off, nothing about an existing spec changes. With it on, people who wanted the feature badly enough could use it, knowing the console output was right and the HTML report was not. It merged on 16 October 2018 and shipped in Gauge 1.0.3.

That part worked as intended. People found it, turned it on, and told us what broke.

## What the flag didn't protect against

The first thing that broke was me. A user asked whether a scenario could load its table from an external CSV file, the way a spec could. I [said yes](https://github.com/getgauge/gauge/pull/1202#issuecomment-443392044). A few weeks later someone tried it, got a parse error, and I had to [correct myself](https://github.com/getgauge/gauge/pull/1202#issuecomment-449906270): it only worked with inline tables. Later that day I [admitted](https://github.com/getgauge/gauge/pull/1202#issuecomment-449913828) the feature was too rough to recommend yet, mostly because the reports didn't support it. External tables at scenario level were [logged separately](https://github.com/getgauge/gauge/issues/1569) and never got done. The lesson I took was small but real: when a feature is half-finished, you can't answer questions about it from what you meant to build. Answer from what's in the code.

The second was a crash, and it was not behind the flag at all. In November 2019 a user running `gauge run --parallel --only <tags>` got a [nil-pointer panic in the HTML report](https://github.com/getgauge/gauge/issues/1529). The cause was in code I'd written for the feature. When parallel runs produce partial results for the same spec, Gauge merges them, and my merge marked the merged spec as table-driven unconditionally. The report plugin believed that, went looking for table rows that didn't exist, and crashed. [The fix](https://github.com/getgauge/gauge/pull/1530) was a few lines: mark it table-driven only if one of the inputs was.

That bug is the useful one. A flag protects you from new behaviour leaking into old specs. It doesn't protect the code paths you had to change on the way, and you change a lot of them for a language feature. The merge path was shared between flagged and unflagged runs, so a mistake in it reached everyone.

## The cost: seven years

Then the flag simply stayed. The core was usable, so the pressure to finish went away. The parts left to do were the unglamorous ones, in other repositories. Each year a few issues arrived: [the flag not working](https://github.com/getgauge/gauge/issues/1565) because of the external-table limit, results [summed up wrong](https://github.com/getgauge/gauge/issues/1802) for some spec shapes, and in 2024 the copy-per-row design I'd flagged in 2018 coming back as [a memory problem](https://github.com/getgauge/gauge/issues/2528) for large tables.

An experimental flag is a promise that the feature will either graduate or be removed. Nobody owned that promise, me included, and a promise nobody owns is not kept.

It was kept in the end because a contributor opened [an issue](https://github.com/getgauge/gauge/issues/2790) in October 2025 with the goal stated plainly: remove the flag and make the feature the default. They'd worked out the current state, listed what was broken, and asked the right design questions, such as whether scenario tables should be allowed inside table-driven specs at all. Another user answered that they relied on exactly that combination for test matrices, so it stayed.

That gave me a reason to come back. In [one pull request](https://github.com/getgauge/gauge/pull/2791) I fixed the scenario counts, the parameter validation and the JSON reporter, and deleted `allow_scenario_datatable`. That was 27 October 2025, seven years and a month after the flag went in. The same contributor then did the larger part of the remaining work: making the results sent to the report plugins say whether a scenario was driven by the spec table, the scenario table or both, with the [row it came from](https://github.com/getgauge/gauge/pull/2798).

For the memory problem I [took a different approach](https://github.com/getgauge/gauge/pull/2792): instead of creating every row's scenario up front, create each one when it's about to run. In the pull request's micro-benchmark, setting up a 1,000-row table went from about 9,000 allocations to 3. Most of that saving is deferred work, not removed work, because each scenario is still built when it runs. But it's only built when it's needed, and it can be dropped once it's done. That pull request is still open, and it adds a flag too: `scenario_init_strategy`, defaulting to `eager`. I noticed the irony. This time the flag exists to keep the old behaviour while people try the new one, and the exit condition is written into the PR: if the feedback is good, lazy becomes the default.

## What I'd keep and change

I'd use the flag again. For a change to what a language means, in a project spread across many repositories, it was the right tool. It let the core ship, it kept existing specs safe, and it put the feature in front of the people who wanted it.

What I'd change is everything around it:

- **Give the flag an exit condition when you add it.** "Experimental until the HTML report and the IDE plugins support it" is a list you can check. "Experimental" on its own never ends.
- **Treat shared code paths as unflagged.** Anything the flagged feature changed that the unflagged path also runs needs the same care as a normal release. The 2019 panic came from exactly there.
- **Write the known debt into the code, not only the pull request.** The copy-per-row note was in a 2018 PR description. It came back as a bug in 2024, and nobody reading the code would have seen it coming.
- **Answer from the code.** Especially about a half-finished feature you wrote yourself.

The feature is finished now, and it's default behaviour. It got there because someone outside the original team cared enough to write down what "done" meant. That's a good outcome, but not a good process to depend on.
