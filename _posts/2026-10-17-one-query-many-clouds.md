---
layout: post
title: "One query, many clouds"
redirect_from: /journal/one-query-many-clouds/
chapter: 7
period: "3 October 2025"
dek: "When the data lives in more than one place, you can move the data to the query or move the query to the data. We spent most of 2025 learning what it takes to do the second."
---

Most query engines assume that all of their workers sit in one network, close to each other and close to the data. For a lot of organisations that stopped being true a while ago. Data lands in whichever cloud the team that produced it was using. One region holds what can't leave that region. A partner's data sits in their account, not yours.

The usual answer is to copy everything into one place first. That works, but it costs egress on every byte, it's always a little out of date, and sometimes it isn't allowed at all.

From May to October 2025 I worked on the other answer: let a single query run across executors in more than one place, and have each part of the query run near the data it reads. Internally we called a group of executors in one location a **fleet**, and a cluster made of several fleets a **hybrid cluster**.

## The cost model changes

Inside one network, the expensive things in a distributed query are CPU, memory and shuffle. Across clouds there's a new cost that dwarfs the others: bytes that cross the boundary. They're slow, they're billed, and they go over links you don't control.

That one fact shaped almost every decision:

- **Scans run where the data is.** Reading a table across a cloud boundary means paying for every byte the scan touches, including the ones a filter is about to throw away.
- **Reduce before you cross.** Filters, projections and partial aggregates should run on the data's side, so what crosses the boundary is already as small as the query allows.
- **The boundary has to be visible in the plan.** If the planner can't see where the expensive edge is, it can't plan around it.

## Run the work near its data

The first piece, in May, was teaching the scheduler that work has a location. Each stage of a query can carry a preference for which fleet should run it, and executors only pick up work meant for their own fleet. Scans of a table go to the fleet that's next to the table's storage.

None of this is a new idea. It's data locality, the same thing Hadoop and Spark have done for years with preferred locations and Presto-style engines do with split placement. What's different is the scale of the penalty. In a single data centre, getting locality wrong costs you a bit of network bandwidth. Across clouds it costs you money on every query.

## Make the boundary an operator

The second piece, from August, was the part I found most interesting. Once stages run in different fleets, data has to move between them somewhere, and it's tempting to hide that inside the existing shuffle machinery. We didn't. Crossing a fleet boundary became its own operator in the plan, a **remote exchange**, with its own statistics.

{% include diagrams/hybrid-cluster.svg %}

Making it explicit paid off in three ways:

- **The planner can reason about it.** It can push filters and partial aggregates below the remote exchange, and it can tell a plan with one crossing from a plan with three.
- **You can see it.** When a hybrid query is slow, the first question is "how much crossed the boundary, and when?" The operator's own stats answer that directly.
- **It can be tested on its own.** The exchange has a clear contract (rows in on one side, the same rows out on the other), and that's much easier to test than behaviour spread across a shuffle.

## Joins across the boundary

Joins were the hardest case. When the two sides of a join live in different fleets, one side has to travel. It's the classic distributed join question with a much steeper price on the wrong answer:

- **Ship the small side.** If one input is small, build the hash table from it and send that table across, then probe it locally against the big side. This is a broadcast join, with the broadcast going over a cloud link.
- **Don't ship either side whole if you can avoid it.** Filter and project first, so the side that travels is only the columns and rows the join needs.
- **Decide with estimates, and be ready to be wrong.** Size estimates are least reliable exactly where they matter most, on filtered intermediate results. A wrong guess here isn't just slow, it's expensive.

By October, joins between fleets worked end to end. Their tests were flaky enough that one had to come out of CI while we chased it down, which brings me to the network.

## Getting packets across at all

Before any of that, executors in different clouds need to reach each other. The options all trade something:

- **Public endpoints with TLS** are simple, but every executor needs to be reachable from the internet.
- **Each cloud's own peering or VPN** works well within a cloud and less well between clouds, and every pair of providers is a different project.
- **An overlay network** gives every node a private address that works the same everywhere.

I spent part of September prototyping the third option on [WireGuard](https://www.wireguard.com/). WireGuard suits this kind of problem: it's small, it's fast, it lives in the kernel, and a tunnel between two machines is just a pair of keys and an endpoint. The hard parts aren't the tunnels. They're everything around them: how nodes find each other, how keys are handed out and rotated, and what happens when a node behind a NAT changes address. I'm not going to go into how we handled those, but if you're starting down this road, budget for the control plane, not the data plane.

## Where we went further

Everything above is the textbook version, and you can build it from ideas that are already public. At [e6data](https://www.e6data.com/) we didn't stop at locality. How our scheduler decides where each piece of a hybrid query runs, and what it's willing to move to get there, is the part of that year I'm proudest of. It's also the part I can't write about yet. If the textbook version is hitting its limits in your own cross-cloud setup, keep an eye on what our engineering team writes up.

## What I'd tell a team going hybrid

- **Make egress the first number in your cost model.** Most of the design falls out of taking it seriously.
- **Put the boundary in the plan.** An explicit operator for "data crosses fleets here" is easier to optimise, observe and test than a property hidden in the shuffle.
- **Locality is old; the penalty is just steeper.** Reuse the ideas every distributed engine already has, and tune them for a much steeper cost of getting it wrong.
- **Expect flaky tests and treat them as signal.** Tests that span fleets fail in ways single-network tests never do. Most of the time they're telling you something true about timing and failure in a real network.
