# Telemetry we added, then deleted

By Srikanth Venugopalan, 5 June 2017. Topics: gauge, open source, privacy.
Canonical: https://sriv.github.io/notes/gauge-telemetry-we-added-then-deleted/

> In 2017 I wired anonymous usage telemetry into Gauge. Two years later we took it all out. Adding it took a few weeks; most of what I learned was about the parts around the ping.

Gauge was built by a small team. We didn't have the time to run user studies or surveys, and we wanted to know which commands and flags people actually used before we changed or deprecated any of them. So in May 2017 the team opened two issues: give every installation an anonymous identifier ([#653](https://github.com/getgauge/gauge/issues/653)), and collect statistics on which commands get run ([#658](https://github.com/getgauge/gauge/issues/658)). I picked them up, and on 5 June 2017 I opened [the pull request](https://github.com/getgauge/gauge/pull/665) that introduced an install ID and sent anonymous events to Google Analytics.

The ping itself was the easy part. A UUID per installation, saved under the user's Gauge config directory. An event per command, sent over the Measurement Protocol, with the IP address anonymised. The rule in the issue was strict and it was the right rule: never record anything specific to the user's project. `gauge run myspecfolder` records that `run` happened, not the folder. `--dir="../"` records nothing about the directory. What we tracked was the language and plugins in the manifest, which execution flags were used (tags, parallel, sort, verbose), and whether refactoring was used, without its parameters.

Everything else took longer than the ping.

## Opt-in or opt-out

The first decision was the default, and I argued for opt-out: on by default, with an easy way to turn it off. The reason I gave at the time was that unattended runs would otherwise never show up. A large share of Gauge runs happened in CI, where nobody is around to answer a prompt, and an opt-in default would have told us about laptops and nothing about pipelines.

That reasoning holds up, but I'd frame the decision differently now. Opt-out isn't a technical default; it's a promise you make to every user who never reads the docs. Keeping that promise is what the rest of this note is about.

The code went in with telemetry disabled while we tested it against a separate analytics account, and the team turned it on for the 0.9.0 release in July 2017. The same day, the project published a post, [Why we collect data](https://gauge.org/2017/07/20/why-we-collect-data/). It said what was collected, where it was stored, who could see it, and how to turn it off. I still think the post mattered as much as the code.

## Human or machine

Once events were flowing, the first problem was that one CI server could run Gauge thousands of times a day, and those runs looked exactly like people. So I added a CI flag to every event ([#702](https://github.com/getgauge/gauge/issues/702)). There's no single standard way to detect CI, so it was a table: `GO_SERVER_URL` for GoCD, `JENKINS_URL` for Jenkins, the TeamCity variable, and `CI=true` for Travis, AppVeyor, CircleCI and the rest. It's an unglamorous list, and it's what made the numbers mean anything: human usage and machine usage answer different questions.

## Fast commands lose their events

Testing turned up something I hadn't expected: quick commands weren't being recorded at all. `gauge uninstall`, `gauge format`, `gauge install` with no arguments. The command finished and the process exited before the HTTP request did. The fix was to make those commands wait for the telemetry request before exiting. That trades a little latency for complete data, and if I did it again I'd put a short timeout on the wait, so a slow network can't hold up someone's terminal.

It's a small bug, but it changes what you can trust. A sampling bias like that doesn't show up as an error. It shows up as "nobody uses `format`", which is exactly the kind of conclusion telemetry was supposed to make safe.

## Off has to be easy in every place Gauge runs

`gauge telemetry off` worked for someone at a terminal. It didn't work for a Docker image, a CI agent built from a script, or a corporate machine provisioned by an installer. So "off" had to exist everywhere:

- An environment variable, `GAUGE_TELEMETRY_ENABLED`, that takes priority over the config file ([#736](https://github.com/getgauge/gauge/issues/736)), with a message that tells you when the variable is the thing deciding.
- A page in the Windows installer to turn it off, and a `/TELEMETRY off` switch for silent installs ([#741](https://github.com/getgauge/gauge/pull/741)). Teammates added the same for the macOS and Linux installers.
- Our own CI pipelines, where we turned telemetry off, so that we weren't counting ourselves.

## Telling people, every time

A year later the team felt that opt-out needed to be more visible ([#1121](https://github.com/getgauge/gauge/issues/1121)). The change was that every `gauge run` would say that telemetry was on and point at how to change it, until the user made an explicit choice. I implemented that in [#1123](https://github.com/getgauge/gauge/pull/1123): Gauge now recorded whether you had actually chosen, not just the current value, and the notice went away once you had. Saying "on" counted as a choice, and so did saying "off".

That's the version I'd start with next time. The notice made opt-out much closer to informed consent, at the cost of one line of output. It's also what a user who never reads the docs actually sees.

## Taking it out

In October 2019 the team decided Gauge no longer needed to keep the data, and [#1490](https://github.com/getgauge/gauge/issues/1490) listed what removing it meant:

1. the telemetry code in Gauge
2. the telemetry code in Gauge's JavaScript packaging
3. the telemetry messages
4. the telemetry configuration
5. the telemetry prompts in the VS Code extension
6. the unique ID generation
7. the documentation
8. the blog post
9. the analytics account itself

Removing it took a teammate's [pull request](https://github.com/getgauge/gauge/pull/1511) and a few weeks, and the `telemetry` command stayed behind as deprecated, so that scripts calling it wouldn't break. The blog post now opens by saying that Gauge no longer collects telemetry, which I think is the right way to leave it: anyone who reads the old explanation sees straight away that it no longer applies.

## What I'd keep

Nine items is the honest measure of what the feature cost. The ping was one of them. The rest was everything a promise to users touches: the installers, the editor extension, the config, the docs, a public post. If I add telemetry to a tool again, I'd write that removal list first, before the first event is sent. Then everyone knows what the feature costs to remove, and it's easier to keep it to what you'd be willing to explain.

The other things I'd keep:

- **Never record anything about the user's project.** Command names and flags, never paths or values.
- **Mark machine runs.** Without a CI flag, the numbers mostly describe CI.
- **Check that short commands still get counted.** Missing data is a bias, and it never shows up as an error.
- **Make off work wherever the tool runs.** Command, environment variable, installer.
- **Tell people, until they've chosen.** One line of output, until the user has picked either way.
