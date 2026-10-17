---
layout: post
title: "Your protocol's worst message is the summary"
tags: [gauge, protocols, design]
when: 2018-11-20
period: "20 November 2018"
dek: "Gauge sent its report plugins one message with the entire run in it. On a big enough suite, protobuf refused to encode it. The fix was to cut the result at a boundary the format already had, and to let each plugin opt in."
---

In November 2018 a user [reported](https://github.com/getgauge/gauge/issues/1239) that Gauge crashed before generating reports on big test runs. The HTML report plugin's log had the line that explained it:

```
Unable to connect to plugin Html Report 4.0.2. proto: message encodes to over 2 GB
fatal error: runtime: out of memory
```

Nothing was wrong with the tests. The run had finished. What failed was the last step: telling the report plugins what happened.

## One message with everything in it

Gauge's core ran specs and talked to plugins over a socket using protobuf messages. Most of those messages were small and frequent: a spec started, a scenario finished. At the very end of a run, Gauge sent each reporting plugin one more message, `SuiteExecutionResult`, holding the complete result of the run: every spec, every scenario, every step, every hook, every captured message, every screenshot. The HTML, XML and JSON reports were all built from it.

It was a natural design. A report is a view of the whole run, so give the reporter the whole run. It's also the one message whose size grows with everything: the number of specs, the length of each, how much each step logs, and how many screenshots it took. Every other message in the protocol was bounded by one event. This one was bounded by nothing.

Protobuf has a hard ceiling of 2 GB on a single encoded message. Long before you reach it, you pay for it twice: the sender holds the entire structure plus its encoded bytes in memory, and the receiver does the same in reverse. In my [comment on the issue](https://github.com/getgauge/gauge/issues/1239#issuecomment-436520941) I put it this way: Gauge can't assume that much memory is available, so the fix is to send the result in chunks rather than move one giant `ProtoSuiteExecutionResult` across at the end.

## Cut where the format already has seams

The question was where to cut. Splitting the encoded bytes into arbitrary pieces would have fixed the transport and nothing else. Both sides would still need the whole thing in memory to encode and decode it, and every plugin would need new reassembly code.

The result already had natural seams. A suite result is a list of spec results. A spec is a list of items: scenarios, steps, comments, tables, tags, in document order. An item is the unit a report renders. So the change, in [gauge-proto](https://github.com/getgauge/gauge-proto/pull/17) and [Gauge](https://github.com/getgauge/gauge/pull/1250), was:

1. Strip the items out of every spec result, and record on each spec how many items it had.
2. Send `SuiteExecutionResult` as before, now a skeleton: the suite totals, the spec headers, and two new fields, `chunked = true` and `chunkSize`, the number of item messages to expect.
3. Send each item as its own message, a new `SuiteExecutionResultItem`. Each item carries a new `fileName` field so the plugin can tell which spec it belongs to.

{% include diagrams/gauge-chunked-result.svg %}

On the other side, the HTML report [collected the items](https://github.com/getgauge/html-report/pull/206) against their specs and built the report once it had received `chunkSize` of them. Apart from the skeleton, each message was now the size of one item rather than the size of the run. Encoding and decoding no longer needed one huge contiguous buffer on either side.

## Who gets the new shape

Gauge had more report plugins than the ones we maintained. Any plugin that received the skeleton without knowing about chunking would see specs with no items, and produce an empty report without any error. That's worse than a crash.

So chunking was opt-in. A plugin declares in its `plugin.json` that it has the `stream_result` capability. When Gauge notifies plugins, it checks each one: a plugin without the capability gets the old single message, as large as it ever was, and a plugin with it gets the skeleton followed by the items. Old plugins kept working exactly as before, including failing on huge runs exactly as before, and new ones could adopt the new shape on their own schedule.

The capability list outlived this change. When the plugin protocol later moved to gRPC, a plugin declared that it could speak it the same way, with `grpc_support`. Once a plugin can say what it understands, the core can add new behaviour without a flag day across every repository.

## What it didn't fix

Chunking fixed the protocol. It did not make the report cheap to build. The HTML plugin still accumulated every item in memory before it rendered anything, because the report it produced, with its suite-wide summary and search index, needs the whole run. A truly streaming report would have rendered each spec's page as its items arrived and kept only totals for the summary. We didn't do that. The 2 GB ceiling went away, but memory still grew with the run.

The problem also came back. In November 2022 a user with about 3,000 scenarios [hit a failure](https://github.com/getgauge/gauge/issues/2305) building the HTML report. By then the plugin protocol ran on gRPC, and the report plugin capped incoming messages at 1 GB. This run sent one of 1.72 GB. There were no screenshots in it. It was response bodies the tests had logged. The [fix that time](https://github.com/getgauge/html-report/pull/291) was a setting, `gauge_max_message_size`, that raises the cap. It unblocked the user, but it's a knob, not a design. Whatever got that large still travelled as a single message.

## The general version

I've since run into the same shape in very different systems. A protocol that is otherwise made of small, bounded, per-event messages has one message that summarises everything, and that message works fine until the day the thing it summarises gets big. It's usually the summary at the end: the final result, the full snapshot, the "here's the state of the world" response to a reconnect.

What I'd take from it:

- **Look for the one message whose size isn't bounded by an event.** Go through the protocol's messages and ask what each one's size grows with. The one that grows with the history or the whole dataset is the one that will fail, and it will fail at the end, after all the work is done.
- **Cut at the seams the data already has.** Splitting bytes fixes the transport limit and nothing else. Splitting at the structure's own units, here spec items, means each piece is meaningful, each side can process pieces independently, and the receiver can actually stream if it chooses to.
- **Send the count up front.** The skeleton told the plugin how many items to expect, so the plugin knew when it was done without a separate end marker, and could tell if something went missing.
- **Let the receiver opt in.** A silent wrong answer, an empty report, is worse than a loud failure. A capability declaration lets old receivers keep the old behaviour and new ones take the new shape.
- **Raising a limit is not a fix.** It is sometimes the right thing to ship on the day, but write down that the real problem is still there.
