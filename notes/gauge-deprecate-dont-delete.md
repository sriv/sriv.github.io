# Deprecate, don't delete

By Srikanth Venugopalan, 21 March 2018. Topics: gauge, protocols, compatibility.
Canonical: https://sriv.github.io/notes/gauge-deprecate-dont-delete/

> Gauge's plugins were written in half a dozen languages, and all of them shared one set of protocol buffer definitions. A small rename taught me that a shared schema has more than one kind of compatibility, and the rule I set afterwards still holds.

Gauge is a small core with a lot of plugins. The language runners execute steps in Java, C#, Ruby, Python, JavaScript and Go. Reporters such as the HTML report turn results into something people read. The editor integrations sit on top. They're separate repositories, released on separate schedules, and often maintained by different people. Each one talks to the core over messages defined in one shared repository, [gauge-proto](https://github.com/getgauge/gauge-proto), which every plugin pulls in and compiles into its own language.

That shared repository is a contract, and in early 2018 I learned that it has more than one side.

## A rename that looked free

In December 2017 the team added fields to carry messages written from hooks onto the report: `preHookMessage` and `postHookMessage` on specs, scenarios and suite results. A few days later they were renamed to the plural, `preHookMessages` and `postHookMessages`, because they're repeated fields. The [rename](https://github.com/getgauge/gauge-proto/commit/26968b9e) kept the field numbers.

On the wire, that's free. Protocol buffers identify a field by its number, not its name. An old runner sending field 8 and a new reporter reading field 8 agree, whatever each of them calls it, so nothing in a running installation breaks.

But wire format isn't the only contract. Every plugin compiles the definitions into code, and the names become the generated names: `getPreHookMessage()` in Java, `PreHookMessage` in Go, the corresponding property in C#. The next time any plugin updated its copy of gauge-proto, code that used the old name stopped compiling, in whichever language that plugin was written in. With protocol buffers there are at least three kinds of compatibility, and a change can keep one and break another:

| What's shared | Identified by | A rename |
|---|---|---|
| The binary wire format | field numbers | keeps it |
| The generated code in each language | field names | breaks it |
| JSON or text renderings of a message | field names | breaks it |

In a single repository you'd rename, fix every call site, and move on. With plugins in six languages in separate repositories, there's no single change that fixes all the call sites. Each plugin finds out on its own, at whatever point it next updates the shared definitions.

## The rule

At the time I was chasing a set of bugs in which messages written from tests weren't showing up in the HTML report, across more than one plugin ([gauge#970](https://github.com/getgauge/gauge/issues/970), [html-report#111](https://github.com/getgauge/html-report/issues/111), [gauge-csharp#117](https://github.com/getgauge/gauge-csharp/issues/117)). On 21 March 2018, while working through them, I opened [gauge-proto#11](https://github.com/getgauge/gauge-proto/pull/11), titled "deprecate instead of removing message fields".

It brought the old names back, as new fields marked deprecated, next to the new ones:

```protobuf
/// [DEPRECATED, use preHookMessages] Additional information at pre hook exec time
repeated string preHookMessage = 10 [deprecated=true];
```

That way any plugin built against either version of the definitions compiled, and the deprecation showed up as a warning instead of a broken build. A field keeps its meaning for good. A replacement is a new field with a new number. The old one is marked deprecated, documented as such, and stays until nobody reads it.

The rule I'd write down for anyone sharing protocol buffer definitions across repositories:

1. **Never change what a field number means.** Not its type, and not its meaning.
2. **Never reuse a number.** If a field really goes away, reserve its number and its name so nobody can bring them back with a different meaning.
3. **Don't rename.** To a consumer in another repository, a rename is a removal plus an addition.
4. **Replace by adding.** New field, new number, old one marked deprecated, with a note saying what to use instead.
5. **Remove last, and on purpose.** Only once you know nothing still reads the old field, and in a release that says so.

## Seven years later

In July 2025 a user asked for timestamps in RFC 3339 format ([gauge#2764](https://github.com/getgauge/gauge/issues/2764)), because the human-readable format Gauge used couldn't tell apart runs that were close together. Changing the existing `timestamp` field's format would have been the smallest diff. It would also have silently broken every reporter that parses the old format, and nothing in the schema would have told them.

So [gauge-proto#111](https://github.com/getgauge/gauge-proto/pull/111) followed the same rule: `timestamp` marked deprecated, and a new `timestampISO` field added next to it on suite, spec, scenario and step results. Old reporters keep reading what they understand, and new ones can switch when they're ready.

The rule doesn't mean nothing ever breaks. In early 2024 I bumped Gauge's minor version in [#2457](https://github.com/getgauge/gauge/pull/2457), and titled the change for exactly what it was: it breaks backward compatibility with plugins. When a break is unavoidable, the version number should say it, and the title should say it too, so that nobody has to work it out from a bug report.

## The rule, as I'd write it now

**A shared schema is an API with several consumers per change.** The wire is one consumer. The generated code in every language is another. Anything that renders messages by name is a third.

**Compatibility is only as wide as the narrowest of those.** "It's binary compatible" is a true statement about one of them.

**Additive change is the cheap kind.** A deprecated field costs a few bytes of schema and a line of documentation. A breaking change costs every downstream maintainer an afternoon, at a time they didn't choose.

**Make the break obvious when you have to make one.** Say it in the version number and in the title, and don't leave it for a downstream maintainer to discover.
