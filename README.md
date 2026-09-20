# FoundationModelsExtras

[![CI](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml)

Shared substrate for the swissarmyhammer FoundationModels family: a
cross-package slash-command vocabulary, a layered `DotfolderStack` for
locating config across defaults/user/project directories, a Stencil-backed
`TemplateEngine` for rendering the content that lives in them — with a
whitelist-and-budget sandbox for rendering untrusted, user-authored
templates — `AgentsMd`, discovery of `AGENTS.md`/`AGENT.md`/`CLAUDE.md`
agent-instructions files with directory-level provenance — and
`MarketplaceStore`, in the separate `Marketplace` product, which fetches a
remote marketplace into a cached, materialized layer root that a stack
reads as it reads a local layer.

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

`StenciledDotfolderStack` renders the files of a stack, and `render(_:in:)`
renders text that the caller holds. A consumer whose own format runs passes
of its own before Stencil marks what those passes spliced in as
quarantined: the render gives each such span to Stencil as a value, thus a
`{{ … }}` inside it stays as it is, and the whole text is one render, under
one set of the limits. The trust and the scope of the partials come from the
layer, the same as for a file:

```swift
let stenciled = StenciledDotfolderStack(base: stack, variables: ["project": "acme"])
let layer = DotfolderStack.Layer(source: .project, root: projectRoot)

let text = QuarantinedText(spans: [
    .original("Project {{ project }}, argument: "),
    .quarantined(argument),  // data: Stencil never scans it
])

let rendered = try stenciled.render(text, in: layer)
// A `.defaults` layer renders trusted; each other layer renders untrusted.
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

## Remote layers: `MarketplaceStore`

A marketplace is a git repository, or a folder on this computer, that holds
entries in the shape of a dotfolder layer: one `<entry>/<document>` for
each entry, with the scripts and the references of the entry beside it.
`MarketplaceStore`, in the separate `Marketplace` product, owns every
marketplace of a host. It fetches each git source with libgit2 into a
cache, writes the selected entries of a commit into a snapshot, and gives
one `MarketplaceLayer` for each source, lowest precedence first. The root
of a git layer is a stable `current` symlink, thus an update swaps the
snapshot under a root that never changes. The initializer reads only the
disk, thus a stack built right after it holds whatever the last run
installed; `start()` then brings each git source to its remote head one
time. A host inserts the layers at the bottom of its `DotfolderStack`, and
reads them as it reads a local layer:

```swift
let store = MarketplaceStore(
    sources: [MarketplaceSource(marketplaceURL)],
    layout: MarketplaceLayout(documentName: "SKILL.md"),
    cacheDirectory: cacheDirectory)
await store.start()

var stack = DotfolderStack(
    name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)
stack.layers.insert(contentsOf: store.marketplaceLayers().map(\.layer), at: 0)

let skill = stack.item(at: "review/SKILL.md")
// skill?.layer.source == .marketplace
// skill?.value.contains("Read the diff first.") == true
```

`marketplaceURL` is one of three source forms: an HTTPS URL that ends in
`.git`, `github:owner/repo`, or a `file://` URL. A `file://` URL that names
a folder and not a `.git` repository is the layer itself; the store makes
no copy of it. `MarketplaceLayout` names the shape of the tree: the
document that marks an entry folder (`SKILL.md` for skills), the folder
names that a scan skips, and the partials folder. This package does not
know what an entry is; the host names its format. `cacheDirectory` has the
default `MarketplaceStore.cacheDirectory()`, which reads
`SKILLS_MARKETPLACE_CACHE` and falls back to `~/.cache/skills/marketplaces`.
`workingDirectory` and `userDirectory` are the values that the host gives
its local layers.

A marketplace layer always renders untrusted, and there is no
per-marketplace permission: the source of the layer is
`DotfolderStack.Source.marketplace`, which is never trusted, and
`MarketplaceSource` has no field that grants anything. `store.events`
reports each check, each update and each failure, and `store.layerUpdates`
sends one value for each swap, because a symlink swap sends no reliable
file-system event to a watcher. `update(_:force:)`, `check()`,
`pin(_:sha:)` and `unpin(_:)` are the commands of a host.

This example is the text between the two marker comments of
`theExampleReadsAMarketplaceSkillThroughTheStack` in
`Tests/MarketplaceTests/ReadmeSnippetTests.swift`, kept green by
`swift test --filter ReadmeSnippetTests`. A second test in that file reads
this README and proves that the two copies are the same text. The test
binds `marketplaceURL` to a repository that `GitFixtureRepository` builds,
and `cacheDirectory`, `workingDirectory` and `userDirectory` to one
temporary folder, thus it touches no network and no home directory.

## Install

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsExtras.git", branch: "main")
```

## Documentation

Design rationale -- the dependency-diamond problem this package solves, all
six pillars, and the untrusted-template sandbox's threat model -- is in
[`plan.md`](plan.md).

## License

No license file is included in this repository.
