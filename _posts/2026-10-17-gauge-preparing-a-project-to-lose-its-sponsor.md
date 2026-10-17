---
layout: post
title: "Preparing an open-source project to lose its sponsor"
tags: [gauge, open source, maintainership]
when: 2020-09-01
period: "1 September 2020"
dek: "When a company stops funding the team behind a project, the code keeps working. Everything around it is what needs preparing: the licence, the release, the contributor terms, and the things that quietly expire."
---

On 1 September 2020 we [announced](https://github.com/getgauge/gauge/issues/1732) that from January 2021, Gauge and Taiko would become fully community-managed projects. After six years of sponsored development, ThoughtWorks would no longer staff a full-time team on them. The announcement was a short Q&A: who does releases, what about licences, should I migrate my tests.

Each of those answers was a promise, and most of the work of that year was making them true. The code was in good shape. What needed preparing was everything around the code that a sponsoring company holds without anyone noticing: the legal paperwork, the release machinery, the signing keys, the accounts. This note is about that work, the parts I did, and the parts teammates did.

## What a sponsor holds without anyone noticing

A sponsored project accumulates things that only work because there is an organisation behind it:

- **A licence chosen years ago**, for reasons nobody quite remembers.
- **A contributor agreement** that someone has to countersign and file.
- **Release steps** that live partly in a CI server and partly in someone's head.
- **Certificates, tokens and accounts** that belong to a company and renew on a company card.

None of these show up in the code. All of them stop working, or stop making sense, when the people who held them move on. The useful exercise is to list them before that happens, and for each one decide: make it public, automate it, or drop it.

## The licence

Gauge core was GPLv3. In April 2020 a would-be adopter [opened an issue](https://github.com/getgauge/gauge/issues/1628) saying their team couldn't adopt Gauge because of how their organisation saw the GPL, and asked whether we'd consider Apache 2.0. The move had already started: zabil had begun relicensing plugins earlier that month, for example the [IntelliJ plugin](https://github.com/getgauge/Intellij-Plugin/pull/435) and [gauge-java](https://github.com/getgauge/gauge-java/pull/427).

I did the [core repository](https://github.com/getgauge/gauge/pull/1632), opened on 29 April and merged on 4 May, and then worked through the rest: [gauge-proto](https://github.com/getgauge/gauge-proto/pull/27), [common](https://github.com/getgauge/common/pull/6), [gauge-dotnet](https://github.com/getgauge/gauge-dotnet/pull/86), [gauge-csharp-core](https://github.com/getgauge/gauge-csharp-core/pull/7), [gauge-csharp-lib](https://github.com/getgauge/gauge-csharp-lib/pull/10), [html-report](https://github.com/getgauge/html-report/pull/261), [xml-report](https://github.com/getgauge/xml-report/pull/25), [Flash](https://github.com/getgauge/Flash/pull/9), [spectacle](https://github.com/getgauge/spectacle/pull/25), an old licence text left in [gauge-java](https://github.com/getgauge/gauge-java/pull/453), and the footer of [the website](https://github.com/getgauge/gauge.org/pull/183).

Two things I took from it. First, a licence change is a sweep, not a commit. A project like Gauge is a dozen repositories, and the licence appears in each one's `LICENSE` file, in file headers, in package metadata and on the website. Second, the place you miss it is the metadata. A few weeks after the main change I was [fixing the licence key](https://github.com/getgauge/gauge/pull/1655) in a Python package's metadata, which is exactly what a package index and a company's licence scanner read first.

## The release

The announcement said releases and build infrastructure were "completely open source and automated using GitHub and GitHub Actions". That was true because of work earlier in 2020 that I didn't do: negiDharmendra and Vinay Shankar Shukla added the release workflows in February, and BugDiver [automated the release](https://github.com/getgauge/gauge/pull/1582) in March. By the time of the announcement, cutting a release no longer depended on a particular machine or a particular person.

Automated releases still need maintaining, and that part kept coming back to me. In late 2020 GitHub deprecated the old way of setting environment variables from workflow steps, and our workflows used it, so I [moved them to environment files](https://github.com/getgauge/gauge/pull/1794). A release pipeline on hosted CI is a dependency on someone else's roadmap. It doesn't need a sponsor, but it does need someone watching the deprecation notices.

## Contributor terms

Gauge had used a contributor licence agreement. A CLA works well when there's an organisation to be the other party to it: someone sends the agreement, someone keeps the signed copies, someone checks them on pull requests.

The announcement said contributions would use the [Developer Certificate of Origin](https://developercertificate.org/) instead. On 1 December I [updated the contributing guide](https://github.com/getgauge/gauge/pull/1799) to match. Mechanically, the DCO moves the statement into each commit: the contributor adds a `Signed-off-by` line, and a check on the pull request looks for it. There's nothing to file and nobody to countersign, which is the property that matters when there may not be an organisation to do either.

## The things that expire

This is the one I'd put first if I did it again.

Our release workflow signed binaries with a code-signing certificate. Certificates expire. In May 2021 ours did, and the release broke. There was no longer a team whose job included renewing it, so on 25 May I [removed code signing from the release workflow](https://github.com/getgauge/gauge/pull/2004), with the commit message "cert has expired", and spent the rest of the day getting the release green again ([1](https://github.com/getgauge/gauge/pull/2005), [2](https://github.com/getgauge/gauge/pull/2006), [3](https://github.com/getgauge/gauge/pull/2007)).

Nothing about that was a surprise in hindsight. The certificate had an expiry date printed on it. What changed was that renewing it had stopped being a routine task and become a decision: who pays, under whose name. A sponsored project doesn't have to answer that question. A community project does, and it's better to answer it on a calm afternoon than on release day.

The same applies to domains, package-registry tokens, CI secrets, cloud accounts that host downloads, and the email address the project's accounts are registered to. Each one has an owner and, often, an expiry date. Each one is a small time bomb if the owner leaves.

## The platform doesn't stop moving

A project without a funded team still has to keep up with everything underneath it. In mid-2021 that meant Apple Silicon: [arm64 support for plugins](https://github.com/getgauge/gauge/pull/2037), [allowing x86_64 plugin binaries to run on arm64 Macs](https://github.com/getgauge/gauge/pull/2045) in the meantime, an arm64 build of [html-report](https://github.com/getgauge/html-report/pull/275), and a [gauge-python dependency bump](https://github.com/getgauge/gauge-python/pull/241) to fix installs on the new machines. Around the same time, a [Go upgrade in CI](https://github.com/getgauge/gauge/pull/2003).

None of that is interesting work. All of it decides whether someone who runs `brew install gauge` on a new laptop gets a working tool.

## Shrinking the surface

The cheapest thing to maintain is the thing you no longer ship. Before the handover we trimmed what we could: the C# plugin came [out of the Windows installer](https://github.com/getgauge/gauge/pull/1763), and the Chocolatey package lost [an install message](https://github.com/getgauge/chocolatey-packages/pull/10) that referred to telemetry Gauge no longer collected. Each artefact you stop producing is one fewer thing that can break on a release day with nobody around.

## What still applies

Gauge is still releasing. As I write this, the latest release went out in October 2026, and I still contribute in my own time. The preparation in 2020 is a large part of why that's possible. The lessons I'd hand to anyone in the same position:

- **Make the release something anyone with commit rights can run.** If a release needs a specific laptop or person, it isn't open source in the way that matters for survival.
- **Inventory everything that expires.** Certificates, domains, tokens, accounts. Write down who owns each one and when it renews, before the people who own them move on.
- **Prefer contributor terms that need no counterparty.** Anything that requires an organisation to sign or file paperwork becomes a blocker the day the organisation steps back.
- **Treat a licence change as a sweep.** Every repository, every header, every package's metadata, the website.
- **Shrink the surface before you lose the people.** Deprecate and remove what you can while there's still a team to do it carefully.
- **Watch your dependencies' roadmaps.** Hosted CI, package registries and operating systems keep changing whether or not your project has funding.

And one that isn't technical. Six years of funded development is what made it possible to hand over something that worked: a tested codebase, automated releases and a community that knew how to contribute. ThoughtWorks sponsored that, and it's why there was something worth preparing.
