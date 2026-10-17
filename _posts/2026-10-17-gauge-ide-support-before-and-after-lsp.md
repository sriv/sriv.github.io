---
layout: post
title: "IDE support, before and after the Language Server Protocol"
tags: [gauge, developer tools, protocols]
when: 2017-11-29
period: "29 November 2017"
dek: "I wrote Gauge's Visual Studio plugin in 2014, when every editor needed its own. Three years later the project moved to a language server. What moved into the server, and what still didn't fit in the protocol."
---

Gauge specifications are Markdown files, and the steps in them are bound to code in Java, C#, Ruby, Python or JavaScript. That makes editor support unusually important for a tool like Gauge. A spec is only pleasant to write if the editor can autocomplete steps you've already implemented, jump from a step to its code, flag a step nobody has implemented yet, and run a scenario from where you're looking at it.

For the first few years, each editor got that through its own plugin.

## One plugin per editor

I started the [Visual Studio plugin](https://github.com/getgauge/gauge-visualstudio) in October 2014. My first autocomplete commit is from 26 October. Within a couple of months it had syntax highlighting for steps, parameters and tags, go-to-definition from a step to its implementation, autocomplete for concepts and nested concepts, highlighting of unimplemented steps, and an action that generated a stub implementation for one. The plugin also hooked into Visual Studio's test runner, so specs and scenarios showed up as tests.

The design was simple. The plugin didn't parse specs itself. From the start it asked a running Gauge process. Gauge exposed an API over a socket, with messages defined in protocol buffers, and the plugin sent requests such as "give me all the steps" and turned the answers into completions. That split was the right instinct, and I'd keep it: Gauge already knew how to parse specs, so the editor shouldn't learn to do it a second time.

What the split didn't remove was everything around the request. For each feature, the Visual Studio plugin still needed:

- the code that starts a Gauge daemon for the open project, waits for it, and handles the cases where Gauge isn't installed or the daemon fails to start;
- the caching, plus file watchers to know when the cached steps had gone stale;
- the mapping from Gauge's answers to Visual Studio's own types for classifiers, completions, glyphs and test cases;
- the integration with debugging, in a way that differed between Visual Studio versions.

All of it was in C#, against Visual Studio's extension APIs. The IntelliJ plugin, which teammates maintained, did the same work in Java against IntelliJ's APIs. Every editor feature was built once per editor, in that editor's language, by whoever knew that editor. That isn't something a small team can keep up for long.

By 2016 the plugin had moved test execution onto a gRPC execution API in Gauge, and that helped. But that moved one feature to a shared API. It didn't move the rest.

## The language server

The Language Server Protocol fixed exactly that shape of problem. The editor speaks one standard protocol for completion, go-to-definition, diagnostics, formatting, symbols and code actions, and a server that understands the language answers. A thin client is enough to get a new editor most of the way.

Gauge's language server came from the team in 2017. Its first commit, in July, did autocomplete. Over the following months teammates added completion for parameters, formatting, execution, and validation errors as diagnostics. The server lived inside Gauge itself, and that mattered: the parser, the validation and the step index that the CLI used were the same ones the editor saw. A step that failed validation on the command line got the same diagnostic in the editor.

My part was in late 2017, next to the new [VS Code extension](https://github.com/getgauge/gauge-vscode). On 29 November I opened [#883](https://github.com/getgauge/gauge/pull/883), which added document symbols and workspace symbols, so that you could jump to any spec or scenario by name in an editor that supports the protocol. The week before, I'd done the change that taught me the most about where the protocol ends.

## What didn't fit

VS Code wanted a test explorer for scenarios ([gauge-vscode#42](https://github.com/getgauge/gauge-vscode/issues/42)): a tree of specs and scenarios that you could run from the sidebar. The Language Server Protocol had nothing for that. It knows about documents, symbols and positions. It doesn't know what a test is, or which test belongs to which file, or what it means to run one.

So [#870](https://github.com/getgauge/gauge/pull/870) added a custom request, `gauge/specs`, which returns the headings of every spec in the project. It's a small change. It's also a reminder that a standard protocol covers what all languages have in common, and a test tool's most important features are the parts that aren't common:

- Which scenarios exist, and in which spec.
- Running one of them, or a set of them, and reporting results while they run.
- Debugging a step, which means a runner in another language has to be started in debug mode and an editor has to attach to it.

Every one of those became a custom request or a feature in the editor extension. The editor-specific code didn't disappear. It got smaller and moved to the edge, and the part that changed most often, the understanding of specs, was written once, inside Gauge.

## Where the standard stops

**Put the understanding in the tool, from the start.** The 2014 plugin got this right before LSP existed: ask Gauge, don't re-parse. Everything that later moved into the language server was already behind an API. What LSP added was a standard way for every editor to ask.

**A standard protocol covers what all languages share.** For a test tool, the valuable part is running things, and the protocol had no word for it. Plan for custom requests, keep them few, and keep them in the same server, so that editors don't fall back to building their own.

**The cost of an editor plugin is the glue around each feature.** Lifecycle, caching, staleness, and mapping to the editor's types. A feature list doesn't show it, which is why one plugin per editor looked affordable until there were several.

The Visual Studio plugin is archived now, and so is the IntelliJ one. The VS Code extension and the language server carried on. I don't mind that ending for the plugin I wrote. It was the right design for 2014, and parts of it, asking Gauge rather than re-parsing, carried straight over into what replaced it.
