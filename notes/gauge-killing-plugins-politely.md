# Killing plugins politely: from a fixed timeout to keep-alives

By Srikanth Venugopalan, 18 January 2019. Topics: gauge, protocols, design.
Canonical: https://sriv.github.io/notes/gauge-killing-plugins-politely/

> Gauge gave every plugin four seconds to exit after a run, then killed it. On large projects that meant killing the HTML report halfway through writing it. The fix was to let the plugin say it was still working, and it came with a limit I'd point out more loudly today.

When a Gauge run finished, the core told each plugin to shut down, waited, and then killed any plugin that hadn't exited. The wait was a setting, `plugin_kill_timeout`, and its default was 4 seconds.

Four seconds is plenty for a plugin that's idle. It isn't enough for one that's busy. The HTML report did most of its work after the run: it received the full result at the end, and then had to render every spec page, copy assets and build a search index. On a large project that took longer than four seconds, so Gauge killed it while it was writing, and the user got a half-written report or none at all. There were reports of this going back to January 2017, [here](https://github.com/getgauge/html-report/issues/120), [here](https://github.com/getgauge/html-report/issues/121) and [here](https://github.com/getgauge/html-report/issues/153).

The workaround was to raise the timeout. That works, but it means every user with a big project has to discover the setting, and every user with a hung plugin waits longer for nothing.

## The issue that framed it

In September 2018 a user, Thunderforge, [opened an issue](https://github.com/getgauge/gauge/issues/1176) with a better framing than any of us had written down. Gauge kills the plugin after a fixed number of seconds, "regardless of if the plugin is actively doing work". It should instead find out whether the plugin is still doing work, and only kill it if it isn't. They suggested one way to tell: look at the timestamps of the plugin's log files.

That's the right question. A fixed timeout tries to tell a slow plugin from a stuck one by how long it takes, and that can't work, because a slow plugin on a big project and a stuck one look identical for the first four seconds, and for the first forty.

## Let the plugin say so

Log-file timestamps are a side channel. They depend on the plugin logging regularly, on where its logs go, and on file-system timestamp granularity. The plugin already had a direct channel to Gauge, though: the socket it received messages on. The plugin is also the only party that actually knows whether it's working.

So I added a message going the other way. In [gauge-proto](https://github.com/getgauge/gauge-proto/commit/a9746e1) it's called `KeepAlive`, and it carries one field, the plugin's ID. Then:

- **Gauge** ([gauge#1309](https://github.com/getgauge/gauge/pull/1309), opened 18 January 2019) listens for `KeepAlive` on each plugin's connection. When it's time to shut down, it starts a kill timer for each plugin, as before. Every `KeepAlive` from that plugin resets its timer. If the timer runs out, the plugin is killed. Gauge also passes the configured `plugin_kill_timeout` to the plugin in its environment, so the plugin knows how often it needs to report in.
- **The HTML report** ([html-report#210](https://github.com/getgauge/html-report/pull/210)) starts a background ping as soon as it receives the suite result. It sends a `KeepAlive` every half of the kill timeout, never more often than every two seconds, framed the same way as every other message on that socket: a varint length followed by the protobuf bytes. When report generation finishes, it stops pinging and exits.

The effect is that the timeout stops meaning "how long a plugin may take" and starts meaning "how long a plugin may go without saying anything". A plugin doing an hour of work can take an hour, and a plugin that goes silent is still killed after four seconds. No user needs to tune anything for the common case.

It's backward compatible in both directions. A plugin that never sends `KeepAlive` gets exactly the old behaviour. A newer plugin talking to an older Gauge sends messages nobody reads, which is harmless.

## Small things the change had to get right

Two details took more care than the idea did.

**The timer is per plugin, and it only exists during shutdown.** Pings that arrive while the run is still going have no timer to reset, and Gauge ignores them. That's fine, because nothing is trying to kill the plugin then. But it means the plugin can't "bank" liveness early. It has to keep pinging until it's done.

**A timer that can be reset has to be cleaned up carefully.** The old code waited on `time.After`, a fresh timer nobody else could touch. The new one is a single `time.Timer` per plugin that two goroutines care about: the shutdown path waits on it, and the keep-alive handler resets it. When the plugin exits first, the shutdown path stops the timer, and if `Stop` says it had already fired, drains its channel, so no expiry is left sitting there. It's three lines, and the kind of three lines that are easy to leave out.

## The limit: alive is not the same as making progress

Here's what I'd say more loudly today than I did then. The HTML report's ping ran on its own goroutine, on a ticker. It proved the process was alive and that its scheduler was running. It did not prove that report generation was getting anywhere. If the report generator had hung inside its own work loop, the ping would have kept going, and Gauge would have waited forever for a plugin that would never finish. Before the change, a stuck plugin cost four seconds. After it, a plugin stuck in the wrong way could hang the end of a CI job until the job's own timeout killed everything.

The stronger version ties the ping to progress. The renderer reports "page 412 of 3,000 done", or at least only sends a heartbeat from inside its work loop, so the ping stops when the work stops. Alongside it you'd want an upper bound that no amount of pinging can extend. We had neither. In practice the HTML report didn't deadlock, so it didn't come up, but "it didn't come up" is not a design.

There's also a smaller edge. Because the ping interval has a floor of two seconds, a user who set `plugin_kill_timeout` below two seconds would see the plugin killed between pings. That's an odd setting to choose, but the code accepted it.

## The pattern

Strip away the specifics and it's the general problem of deciding when another process has failed. The supervisor can't see inside the worker. Elapsed time is the only thing it measures directly, and elapsed time can't tell a slow worker from a stuck one. Every reasonable answer moves the evidence to the party that has it. The worker sends heartbeats, a lease it renews, or progress reports, and the supervisor only judges silence.

What I'd take from Gauge's small version of it:

- **A fixed timeout is a guess about the workload.** It's wrong for the big projects, and the big projects are the ones that matter.
- **Put the evidence where the knowledge is.** The plugin knows if it's working. Ask it, over the channel you already have, not through log files.
- **Make silence the failure, not duration.** Reset on every heartbeat, and keep the timeout short.
- **A heartbeat from a separate thread proves liveness, not progress.** If a hang is a failure you care about, the heartbeat has to come from the work itself, and there has to be a ceiling it can't extend.
- **Make it optional for the other side.** A worker that never heartbeats should get the old behaviour, not a new failure.
