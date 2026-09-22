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

### Where an include finds a partial

An `{% include "_partials/x" %}` walks from the folder of the document up to
the layer root, and the most specific folder wins. For a document at
`skills/commit/SKILL.md` the walk searches these folders, in this order:

```
skills/commit/_partials/x.md    the partials of one skill
skills/_partials/x.md           the partials of the skills
_partials/x.md                  the partials of the whole layer root
```

At each folder the walk checks each layer in scope, the highest first, and
the first copy that it finds wins. Thus a copy in a more specific folder of
a lower layer wins over a copy in a less specific folder of a higher layer;
in one folder, the highest layer wins, as before. A skill at
`commit/SKILL.md` and an agent at `agents/committer.md` of one root both
find `_partials/x.md` at that root, and a `commit/_partials/x.md` wins for
that one skill only. The walk never goes above the layer root, and each path
that it tries goes through the confinement checks of `DotfolderStack`.

The file lookups of `StenciledDotfolderStack` walk from the folder of each
file. `render(_:at:in:)` renders text that the caller holds as the document
at a path relative to the layer root, with the same walk. `render(_:in:)`
has no path, thus it searches the layer root only. When no folder holds the
partial, the failure lists each folder that the walk searched, in the order
of the search.

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

The root of a git layer also holds the agents of the marketplace, in one
flat folder: `agents/<file name>.md`, one `.md` file for each agent, and the
file name is the agent name. `MarketplaceLayer.agentsDirectoryName` names
the folder. A catalog plugin gives the files of its `agents` list, which are
paths relative to the plugin source; an entry that is not an `.md` file gets
a diagnostic and is skipped. A plugin with no `agents` list gives each `.md`
file directly in `<plugin source>/agents/`, and a tree with no catalog gives
each `.md` file directly in `<root>/agents/`; a subfolder of `agents/` is not
read. When two plugins give the same file name, the later plugin wins, with
one diagnostic, as for skills. `SkillSelection.all` and `.plugins([...])`
take the agents of the selected plugins; `.skills([...])` takes none. The
agent files count toward the `SnapshotLimits` of the policy. The name
`agents` is reserved at the layer root, thus a skill folder with that name
gets a diagnostic and is not in the layer. This package copies each agent
file by name and reads no agent frontmatter. A consumer reads
`<layer root>/agents/*.md` from each layer of `marketplaceLayers()`, and
reads them again on each `layerUpdates` value; an agent body can include a
partial of the partials folder of the same layer.

The snapshot is flat: a skill is at `<snapshot>/<skill>/`, and the folders
between a plugin source and a skill, for example `skills/` and
`skills/group/`, are not in it. Thus the partials of those folders merge into
`<snapshot>/_partials/`. For each selected skill, the snapshot takes each
folder from the plugin source (for a tree with no catalog, the root) down to
the folder that holds the skill. It copies the `_partials/` of each of these
folders one time, from the least specific (the fewest path components) to
the most specific. For a skill at `skills/group/review/`, the order is:

```
_partials/                 the plugin source
skills/_partials/          less specific
skills/group/_partials/    the most specific: it wins
```

The `<plugin source>/_partials/` of a plugin that gives only agents is
copied too. A copy from a more specific folder replaces a copy of the same
name from a less specific folder, with no diagnostic, whatever the catalog
order. Two folders at the same level that give a partial of the same name,
for example `skills/group-a/_partials/x.md` and
`skills/group-b/_partials/x.md`, or the source roots of two plugins: the
later one in catalog order wins, with one diagnostic. A `_partials/` folder
inside a skill folder goes with the skill folder, and the include walk finds
it at `<snapshot>/<skill>/_partials/`, where it wins for that skill. A known
limit of the flat snapshot: each skill and each agent sees the merged
partials of all these folders, because they merge into the one
`<snapshot>/_partials/`.

A marketplace layer always renders untrusted, and there is no
per-marketplace permission: the source of the layer is
`DotfolderStack.Source.marketplace`, which is never trusted, and
`MarketplaceSource` has no field that grants anything. `store.events`
reports each check, each update and each failure, and `store.layerUpdates`
sends one value for each swap, because a symlink swap sends no reliable
file-system event to a watcher. `update(_:force:)`, `check()`,
`pin(_:sha:)` and `unpin(_:)` are the commands of a host.

`MarketplaceStore.listings(of:cacheDirectory:)` is the read behind a list
command. It reads `state.json` of the cache, opens no connection and needs
no store, and it gives one `MarketplaceListing` for each source: the name,
the pre-fetch key, the normalized URL, the current commit, the catalog
version, the last check, whether the marketplace is a folder on this
computer, whether it holds one commit, and the message of the last failure.
A source whose URL is of no supported form gives a listing that carries the
message of the parser, thus a list shows every source that the host named.
`MarketplaceStore.cacheDirectoryVariable` and
`MarketplaceStore.seedDirectoryVariable` name the two environment variables
of the cache, so a host and a test both set them by name. The layout of the
cache stays inside the product: no public type names a folder of it or a
file in it.

This example is the text between the two marker comments of
`theExampleReadsAMarketplaceSkillThroughTheStack` in
`Tests/MarketplaceTests/ReadmeSnippetTests.swift`, kept green by
`swift test --filter ReadmeSnippetTests`. A second test in that file reads
this README and proves that the two copies are the same text. The test
binds `marketplaceURL` to a repository that `GitFixtureRepository` builds,
and `cacheDirectory`, `workingDirectory` and `userDirectory` to one
temporary folder, thus it touches no network and no home directory.

### Example: a marketplace under local folders

A marketplace gives the skills. The local folders of the host change them.
With these files:

```
team-skills/skills/review/SKILL.md      Review {{ project }}. {% include "rules.md" %} {% include "footer.md" %}
team-skills/skills/deploy/SKILL.md      Marketplace deploy of {{ project }}.
team-skills/skills/_partials/rules.md   Marketplace rules.
team-skills/skills/_partials/footer.md  Marketplace footer.
~/.config/myagent/_partials/rules.md    User rules.
<cwd>/.myagent/deploy/SKILL.md          Project deploy of {{ project }}.
<cwd>/.myagent/local/SKILL.md           Local skill. {% include "footer.md" %}
```

the host puts the marketplace below its local folders and renders with
Stencil:

```swift
// Local folders: user (~/.config/myagent) < project (<cwd>/.myagent).
var stack = DotfolderStack(
    name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)

// The marketplace goes BELOW the local folders, so a local copy wins.
let store = MarketplaceStore(
    sources: [MarketplaceSource(marketplaceURL)],
    layout: MarketplaceLayout(documentName: "SKILL.md"),
    cacheDirectory: cacheDirectory)
stack.layers.insert(contentsOf: store.marketplaceLayers().map(\.layer), at: 0)

// Stencil renders each file that a lookup gives.
let skills = StenciledDotfolderStack(base: stack, variables: ["project": "acme"])
    .items(in: nil, named: "SKILL.md")

// skills["review"]  from .marketplace: "Review acme. User rules. Marketplace footer."
// skills["deploy"]  from .project:     "Project deploy of acme."
// skills["local"]   nil: a local file cannot include a marketplace partial
```

The rules:

| Case | Result |
|---|---|
| Only the marketplace has a skill | The marketplace copy |
| The project has the same skill | The project copy |
| The user has a partial that a marketplace skill includes | The user copy |
| A marketplace skill includes a partial that only its marketplace has | The marketplace copy |
| A local skill includes a partial that only a marketplace has | A render failure: the skill is not in the result, and the failure goes to `onDiagnostic` |

The last rule keeps a local file independent of a remote source. Each rule
is one test in `Tests/MarketplaceTests/LayerPrecedenceExampleTests.swift`,
and a test in that file proves that this block and the test copy are the
same text: `swift test --filter LayerPrecedenceExampleTests`.

## Watching the layers: `DotfolderWatcher`

`DotfolderStack` holds no cache: each lookup reads the disk at the time of
the call. A consumer that caches what a lookup gave must know when a layer
changed, and `DotfolderWatcher` is that signal. It watches the tree of each
layer root recursively, joins a burst of file system events into one
`onChange` call after a quiet period, and says nothing about WHAT changed:
the consumer reads the stack again. A layer root that is not on disk at
`start()` is armed at its nearest existing ancestor, thus the later creation
of that root fires the callback too:

```swift
let stack = DotfolderStack(
    name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)

let watcher = DotfolderWatcher(stack: stack) {
    // A layer changed on disk. The stack holds no cache, thus the next
    // lookup gives the new files.
    reload()
}
watcher.start()
defer { watcher.stop() }
```

`init(roots:)` takes the roots directly, for a consumer that watches folders
that no stack holds. `debounceInterval` has the default 200 ms. `stop()`
closes each file descriptor and is safe to call from inside `onChange`, and
`deinit` calls it.

This example is mirrored in `readmeStackWatcherExample` in
`Tests/FoundationModelsExtrasTests/DotfolderWatcherTests.swift`, kept green by
`swift test --filter DotfolderWatcherTests`. The test binds
`workingDirectory` and `userDirectory` to one temporary folder, thus it
touches no home directory.

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
