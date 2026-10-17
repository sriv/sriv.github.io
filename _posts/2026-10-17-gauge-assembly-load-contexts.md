---
layout: post
title: "Loading someone else's code: AppDomains, then AssemblyLoadContext"
tags: [gauge, dotnet, runtime]
when: 2020-08-14
period: "14 August 2020"
dek: "A test runner has to load the user's assemblies into its own process. On .NET Framework I used an AppDomain for that. On .NET Core there are none, and the replacement taught me that isolation, file locks and native dependencies pull in different directions."
---

A test runner for a compiled language has an awkward job. It's a program with its own dependencies, and it has to load *your* program, with your dependencies, into the same process, find your step methods by reflection, and call them. If the two sets of dependencies disagree, something has to give.

I've had to solve this twice for Gauge's C# support, five years apart, on two different runtimes.

## 2015: an AppDomain

The first C# runner targeted .NET Framework, which has AppDomains: isolated regions inside one process, each with its own set of loaded assemblies. In March 2015 I put the user's test code in a sandbox AppDomain, separate from the runner's.

That gave real isolation, and charged for it at every boundary. Anything crossing between domains has to be marshalled: serialisable, or a proxy to an object on the other side. The commit history from that month is mostly me learning this, down to passing types across as strings because the real objects wouldn't marshal. It kept charging for years. In 2018 the execution context had to be serialised before it could be sent into the domain, and a `ConcurrentBag` that was fine on Windows broke the Linux build because Mono wouldn't carry it across domains.

Still, it worked, and users mostly never thought about it.

## .NET Core has no AppDomains

When Gauge got a runner for .NET Core, the AppDomain option was gone; .NET Core supports exactly one per process. For a while the runner simply loaded every assembly from the project's build output with `Assembly.LoadFrom`, into the default context alongside its own.

That's fine until the user's project depends on something that isn't just a managed DLL. In 2020 we started getting reports from people connecting to SQL Server from their tests: `System.Data.SqlClient is not supported on this platform` ([#80](https://github.com/getgauge/gauge-dotnet/issues/80), [gauge#1711](https://github.com/getgauge/gauge/issues/1711)), and, after a suggested workaround, `BadImageFormatException` ([#85](https://github.com/getgauge/gauge-dotnet/issues/85)).

The cause is that packages like SqlClient ship more than one build of the same assembly: a placeholder that throws "not supported", plus platform-specific implementations and native libraries under a `runtimes/` folder. Which one you get is decided by the project's `.deps.json`, which the .NET host reads when it starts *your* application. Loading DLLs off disk by hand skips all of that, so the runner was picking up the placeholder.

## A load context per job

.NET Core's replacement for this kind of isolation is `AssemblyLoadContext`. You subclass it, decide how each assembly name is resolved, and load into it. The piece that made it fit was `AssemblyDependencyResolver`, which reads a `.deps.json` the same way the host does and resolves both managed assemblies and native libraries to the right platform-specific files.

[The change in August 2020](https://github.com/getgauge/gauge-dotnet/pull/106) put the user's assemblies into a `GaugeLoadContext` that asks the resolver for every name. SqlClient got its real implementation. The old hand-written assembly loader went away, and so did two features that only existed to paper over the old model: a setting for extra library folders, since .NET wants those as package, project or DLL references in the project itself, and an older screenshot interface, which now produced a clear error pointing to its replacement while the run carried on.

## Then the files were locked

A month later, a different report: debugging from VS Code failed because the build couldn't overwrite DLLs in the output folder; [another process was using them](https://github.com/getgauge/gauge-dotnet/issues/114). That other process was the Gauge runner, running behind the editor's language server to power completion and navigation.

`LoadFromAssemblyPath` keeps the file open. That's harmless for a test run that loads, executes and exits. It's not harmless for a runner that stays up as long as the editor does while the user rebuilds the same files.

My first fix [made the context collectible](https://github.com/getgauge/gauge-dotnet/pull/115) and unloaded it after scanning when serving the editor. That released the files, but it fought with execution, which needs the reflected types and methods to still be there when it runs them.

The [version that stuck](https://github.com/getgauge/gauge-dotnet/pull/119) separated the two jobs. For authoring, a `LockFreeGaugeLoadContext` reads each assembly into memory with `LoadFromStream`, so nothing on disk stays open. For execution, the original path-based context stays, because some packages carry runtime-specific pieces that are risky to load from raw bytes; that's the `BadImageFormatException` again. The comment I left in that class says both halves, because the next person to touch it would otherwise "simplify" it back into one.

## If you're hosting user code

- **Isolation is a cost you pay at every boundary.** AppDomains bought clean separation and charged for it in marshalling for as long as they were in use.
- **Use the platform's resolver.** The runtime already knows how to pick the right build of a dependency for this OS and CPU. A runner that loads DLLs by hand is quietly reimplementing that, badly.
- **The same code can have two jobs with opposite needs.** Execution wants faithful loading and doesn't care about locks. An editor wants files left alone and can tolerate a lighter load. Two contexts was the honest answer, not a hack.
