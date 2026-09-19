# FoundationModelsExtras

[![CI](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml)

Shared substrate for the swissarmyhammer FoundationModels family: a
cross-package slash-command vocabulary, a layered `DotfolderStack` for
locating config across defaults/user/project directories, a Stencil-backed
`TemplateEngine` for rendering the content that lives in them — with a
whitelist-and-budget sandbox for rendering untrusted, user-authored
templates — and `AgentsMd`, discovery of `AGENTS.md`/`AGENT.md`/`CLAUDE.md`
agent-instructions files with directory-level provenance.

```swift
import FoundationModelsExtras
import Foundation

let stack = DotfolderStack(
    name: "myagent",
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
)

let engine = TemplateEngine(partials: stack)

var context = TemplateContext()
context.set(key: "name", to: .string("world"))

// `trust: .untrusted` runs a tag/filter whitelist plus include-depth,
// output-size, and iteration budgets -- for content it didn't ship itself,
// use `.trusted` for its own shipped defaults.
let greeting = try engine.render(
    "Hello {{ name }}! Config lives under .{{ dotfolder_name }}/.",
    context: context,
    trust: .untrusted
)
// greeting == "Hello world! Config lives under .myagent/."
```

## Ignoring files: `IgnoreProcessor`

`IgnoreProcessor` implements `gitignore(5)` matching semantics -- last-match-
wins, negation, anchoring, directory-only rules, and parent-directory
exclusion -- and loads rules from any file name, not just `.gitignore`.
Combine several sources with `+` (or accumulate with `+=`): the right
operand's rules are appended after the left's, so under last-match-wins
evaluation the right operand overrides the left wherever both match, the
same layering git itself applies across its own ignore sources. Every
`evaluate` call returns an `IgnoreVerdict` whose `description` explains
itself in one line, citing the deciding rule's source file and line:

```swift
let ignores =
    try IgnoreProcessor(contentsOf: gitignoreURL)
    + IgnoreProcessor(contentsOf: reviewignoreURL)

let verdict = ignores.evaluate("debug.log")
// verdict.isIgnored == true
// verdict.description == "ignored by \".gitignore\":1 `*.log`"
```

This exact sequence of calls is mirrored in
`readmeGitignoreAndReviewignoreCombinationExample` in
`Tests/FoundationModelsExtrasTests/IgnoreProcessorTests.swift`, kept green by
`swift test --filter IgnoreProcessorTests`.

## Health checks: `Doctorable`

A CLI needs one command that answers one question: will this configuration
work? `Doctorable` is how each component answers for itself, because it is
the only part that knows its own subject. A component reports a list of
named `HealthCheck` findings, each with a status, a message, and -- when
something is wrong -- the command that fixes it. `DoctorRunner` asks every
applicable component at the same time and gathers the findings into one
`DoctorReport`, in registration order, so two runs of the same
configuration read the same way:

```swift
struct TranscriptStore: Doctorable {
    let doctorName = "transcripts"
    let doctorCategory = "storage"

    func runHealthChecks() async -> [HealthCheck] {
        [
            .error(
                name: "transcripts directory",
                message: "~/.myagent/transcripts is not there",
                fix: "myagent init",
                category: doctorCategory)
        ]
    }
}

let runner = DoctorRunner(components: [TranscriptStore()])
let report = await runner.run()
// report.worstStatus == .error
// report.exitCode == 1
```

`report.exitCode` is what a script reads:

| Code | Meaning |
|---|---|
| 0 | Every check is `.ok` |
| 1 | At least one `.error` |
| 5 | At least one `.warning`, and no `.error` |

The two outputs go to different places: `PlainTextDoctorRenderer` writes
the table to stderr, because a report is a diagnostic, and `--json` writes
`DoctorReport.jsonData()` to stdout, because a script reads it. The plain
renderer never writes an escape sequence, so a pipe and a file get stable
text. `HealthCheck` and `DoctorReport` are `Codable`, and the report encodes
as the one JSON array of its checks. This package declares no terminal
dependency -- it is a library that also runs inside a Mac app -- so a CLI
that wants a decorated table renders the `DoctorReport` itself.

Run the whole surface, exit code included, with
`swift run extras-demo doctor --scenario mixed`. That scenario reports one
finding of each status, so its worst finding is an `.error` and it exits
`1`.

## Running a process: `ProcessRunner`

`ProcessRunner` runs one executable directly, with no shell, in its own
process group. It merges stdout and stderr into one bounded tail, in
arrival order, so the caller holds no more memory than the `OutputCap`
permits, however much the process writes. At the timeout it sends
`SIGKILL` to the whole group, so a grandchild the process put in the
background dies with it. The pid stands in a `ProcessRegistry` from the
spawn to the reap. The `registry` parameter defaults to
`ProcessRegistry.global`, so the `atexit` sweep of that registry is the
backstop for a run that a normal exit of the host cuts short:

```swift
let outcome = try await ProcessRunner.run(
    executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "echo building; echo warning: slow >&2; exit 2"],
    workingDirectory: FileManager.default.temporaryDirectory,
    timeout: .seconds(30),
    outputCap: ProcessRunner.OutputCap(lineCount: 64, byteLimit: 65_536)
)
// outcome.termination == .exited(code: 2)
// outcome.output == ["building", "warning: slow"]
// outcome.isTruncated == false
```

`outcome.termination` is `.exited(code:)`, `.signaled(_:)`, or `.timedOut`.
`outcome.lineCount` is the count of all the lines the process wrote, and
`outcome.isTruncated` marks a cut by the cap. The call throws
`ProcessRunner.Failure` when the spawn did not reach exec, or when the reap
failed.

This call is mirrored in `readmeExitCodeAndMergedOutputExample` in
`Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift`, kept green by
`swift test --filter ProcessRunnerTests`. The test gives the runner a
private `ProcessRegistry`, because the suites of the package run at the
same time in one process.

## Install

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsExtras.git", branch: "main")
```

## Documentation

Design rationale -- the dependency-diamond problem this package solves, all
four pillars, and the untrusted-template sandbox's threat model -- is in
[`plan.md`](plan.md).

## License

No license file is included in this repository.
