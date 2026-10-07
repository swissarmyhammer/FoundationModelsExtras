# FoundationModelsExtras

[![CI](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsExtras/actions/workflows/ci.yml)

Shared substrate for the swissarmyhammer FoundationModels family: a
cross-package slash-command vocabulary, a layered `DotfolderStack` for
locating config across defaults/user/project directories, a Stencil-backed
`TemplateEngine` for rendering the content that lives in them — with a
whitelist-and-budget sandbox for rendering untrusted, user-authored
templates — `AgentsMd`, discovery of `AGENTS.md`/`AGENT.md`/`CLAUDE.md`
agent-instructions files with directory-level provenance —
`MarketplaceStore`, in the separate `Marketplace` product, which fetches a
remote marketplace into a cached, materialized layer root that a stack
reads as it reads a local layer — `GenerationQueue`, the one work queue
of each resident model in a process — `ModelPool`, which loads each model
one time in a process and shares it through holds — `Mailbox`, which lets
a caller post messages to a session and not wait — and tool hosting
(`ToolContext`, `RunPlane`), which runs the tools of a session in band or in
the background.

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

## One model, one queue: `GenerationQueue`

One GPU runs one generation at a time. Thus each resident model has one
`GenerationQueue`, and every caller in the process that uses the model
submits to that queue. An item is one whole call to the model. One worker
runs the items one at a time, first in first out. The queue is not a lock: a
caller waits only for the result of its own item. A cancel of a caller that
waits removes its item from the queue at once, and a cancel of a caller whose
item runs cancels the task of that item.

`submit(onQueued:_:)` calls `onQueued` only when the item must wait behind
another item, thus a session can report the wait. The re-entry guard stops a
deadlock: a tool body that runs inside an open submission, and that submits
to the same queue, could never run, because its item waits for the item of
the tool body. The owner of the model call binds a `ModelCallMark` that
names the queue and the model (a `SubmissionTarget`), and the queue refuses
that submission at once with `GenerationQueueError.waitInsideOpenSubmission`:

```swift
let model: ModelRef = "mlx-community/Qwen3-8B-4bit"
let queue = GenerationQueue()

// Each call to the model is one item. One worker runs the items one at
// a time, first in first out. `onQueued` runs only when the item must
// wait behind another item.
let answer = try await queue.submit(onQueued: { waits.add(1, ordering: .relaxed) }) {
    "an answer from \(model.stringValue)"
}

// A tool body inside an open submission must not wait for the same
// queue: that submission runs only after the tool body ends. The
// owner of the call binds a mark, and the queue refuses the wait.
let mark = ModelCallMark(
    sessionID: ULID(), submission: SubmissionTarget(queue: queue, model: model))
do {
    _ = try await ModelCallMark.$current.withValue(mark) {
        try await queue.submit { "this item never runs" }
    }
} catch GenerationQueueError.waitInsideOpenSubmission(let refused) {
    refusedModel = refused
}
mark.close()
```

A declared background run is not refused: `ModelCallMark.withBackgroundRunMark`
gives it a closed mark of the same session, because it does not hold the
worker. Inside, the queue is one worker loop over an `AsyncStream` of items.
Each item keeps its state (new, waiting, running, finished) under one lock,
thus a cancel acts at once on the task that cancels, and only one path
resumes the caller. Each item runs on a detached task, which inherits no
task-local of its caller.

This example is mirrored in `readmeWorkQueueExample` in
`Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueuePublicSurfaceTests.swift`,
kept green by `swift test --filter GenerationQueuePublicSurfaceTests`. The
test declares `waits` (an `Atomic<Int>`) and `refusedModel` before the block.

## One load for each model: `ModelPool`

In one process, each model loads one time, and all users share it.
`acquire` gives a `ModelHold`. A resident key adds a hold at once. A new key
loads as one job in the admission queue of the pool, so two callers of one
new key cause one load. The first loader of a key wins: a later caller gets
that container, whatever loader it gives. Thus use the container through a
protocol, never by a cast to the container type of one loader.

### Load by name: `MLXModelLoader`

`MLXModelLoader` is the built-in loader. It loads an MLX model from its Hugging
Face name, and downloads the model when the Hugging Face cache does not hold
it. An `.llm` key gives an `MLXLanguageModel` (a FoundationModels
`LanguageModel` with guided output, tool calls and a reasoning trace). An
`.embedding` key gives a `PooledEmbedding`.

`MLXModelLoader(tokenizerLoader:)` sets the tokenizer loader (a `TokenizerLoader`
of `MLXLMCommon`) of each load, of an LLM and of an embedding model. For
example, give a tokenizer loader that loads the chat template with a pinned
date. `nil`, the default, uses the Hugging Face tokenizer loader
(`#huggingFaceTokenizerLoader()`), thus `MLXModelLoader()` loads as before.
Thus a package that needs its own tokenizer does not make its own
`MLXLanguageModel`. The integration test `aLoadUsesTheGivenTokenizerLoader` in
`IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/MLXModelLoaderIntegrationTests.swift`
loads a real LLM and a real embedding model with a tokenizer loader that
records each call.

`ModelPool(loader:)` sets the loader of the pool. The default is
`MLXModelLoader()`, and `ModelPool.shared` uses it. `acquire(_ key:)` loads
with the loader of the pool, and needs no loader and no byte count. After the
load, the loader measures the model with `footprintBytes(of:)`, and the pool
counts that footprint. `MLXModelLoader` measures the weight files of the model
in the Hugging Face cache. A loader that does not implement
`footprintBytes(of:)` counts 0 bytes. When the measure throws, the loader
evicts the model, and `acquire` throws:

```swift
// The shared pool loads with MLXModelLoader: no loader, no byte count.
let chat = ModelPoolKey(ref: "mlx-community/Qwen3-4B-4bit", role: .llm)
let chatHold = try await ModelPool.shared.acquire(chat)

// A test gives its own loader. All of this API is public.
let testPool = ModelPool(loader: fakeLoader)
let testHold = try await testPool.acquire(chat)
```

`acquire(_:footprintBytes:sessionBytes:loader:)` stays, for a caller that
gives its own loader and its own byte counts. The integration test
`acquireByKeyLoadsEachModelByName` in
`IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ModelPoolIntegrationTests.swift`
loads a real LLM and a real embedding model by name through `ModelPool()`.

### Holds, eviction and admission jobs

The `deinit` of a hold releases it. After the last hold, the pool puts an
eviction job in the admission queue. That job checks the hold count again, so
an `acquire` between the release and the job keeps the model resident.

The pool counts an evicted model until the `evict` call of its loader
returns, because the model uses its memory until then. While that call runs,
`footprint`, each value of `footprints`, `isResident` and `residentModelCount`
still show the model, but the model gives no hold: an `acquire` of its key
loads the model again after the eviction job.

`admit` runs a job of your own in the same queue. A job that reads the
footprint and then loads sees no other load or eviction between the two
steps. Inside the job, acquire through the `ModelPoolAdmission` that the job
gets, because `ModelPool.acquire` waits for the end of the job:

```swift
let pool = ModelPool()
let chat = ModelPoolKey(ref: "mlx-community/Qwen3-8B-4bit", role: .llm)
let embedding = ModelPoolKey(ref: "mlx-community/bge-small", role: .embedding)
let chatBytes: Int64 = 5_000_000_000
let sessionBytes: Int64 = 500_000_000
let embedderBytes: Int64 = 200_000_000
let budgetBytes: Int64 = 8_000_000_000

// A resident key adds a hold at once. A new key loads in the admission queue.
let chatHold = try await pool.acquire(
    chat, footprintBytes: chatBytes, sessionBytes: sessionBytes, loader: loader)

// One admission job reads the footprint and loads. No other load can
// run between the read and the load.
let embedderHold = try await pool.admit { admission -> ModelHold? in
    let fits = admission.footprint.totalBytes + embedderBytes <= budgetBytes
    return if fits {
        try await admission.acquire(embedding, footprintBytes: embedderBytes, sessionBytes: 0, loader: loader)
    } else {
        nil
    }
}
```

`footprints` gives a new `AsyncStream` for each call: the current
`ModelPoolFootprint` first, then each change, with the bytes of a load that
runs now in `loadingBytes`. `ModelPool.shared` is the pool of the process.

This example is mirrored in `readmeModelPoolExample` in
`Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`, kept green
by `swift test --filter ModelPoolTests`. The test declares `loader` (a
`PooledModelLoader`) before the block.

### Load progress: `progress(for:)`

`progress(for:)` gives a new `AsyncStream<ModelLoadProgress>` for each call. It
shows the next load of a `ModelRef`, or the load that runs now:
`downloading(completedBytes:totalBytes:)` values while the model downloads,
then `loading`, then `ready` or `failed(String)`. The stream then ends. All
streams of one load get the same values. A stream that starts during a load
gets the last value of that load first. A stream that starts when the model is
resident gives `ready` at once and ends. A download value has the real byte
counts of the download, and its `fraction` property is `completedBytes` over
`totalBytes`. The `completedBytes` of the download values of a stream do not
decrease.

Each load gives its progress to the stream, whatever acquire method started
it: `acquire(_:)`, `acquire(_:footprintBytes:sessionBytes:loader:)`, or an
acquire inside `admit(_:)`. The loader reports the download and the load
through `load(key:progressHandler:)` of `PooledModelLoader`. `MLXModelLoader`
reports the completed bytes and the total bytes of the files of the repository
that the Hugging Face downloader gives, and all the bytes when the download
ends, then `loading`. A model that the Hugging Face cache holds at a pinned
commit downloads nothing, and gives no download value. A loader that
implements only `load(_:)` reports `loading`. The pool reports `ready` or
`failed`, and gives `loading` before `ready` when the loader did not report it.
The pool drops a report that breaks this order, a download value with fewer
completed bytes than the download value before it, and a report of a load that
ended:

```swift
let progress = pool.progress(for: chat.ref)
async let hold = pool.acquire(chat)
for await step in progress {
    show(step)   // downloading(completedBytes:totalBytes:)..., loading, then ready or failed
}
```

This example is mirrored in `readmeProgressExample` in
`Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift`,
kept green by `swift test --filter ModelLoadProgressTests`. The test declares
`pool` (a `ModelPool(loader:)` with a test loader that reports progress),
`chat` (a `ModelPoolKey`) and `show` before the block. The integration test
`aLoadEndsWithReady` in
`IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ModelPoolIntegrationTests.swift`
loads a real model and reads its progress.

### One queue for each model: `PooledEmbedder`

Each resident model has one `GenerationQueue`, and all holds of its key share
it as `hold.queue`. The queue keeps its guard: a submission from inside an open
submission on the same queue is refused.

For a key of the `.embedding` role, the loader returns a container that
conforms to `PooledEmbedding`. `PooledEmbedder(ref: "<Hugging Face name>")` makes
an embedder and loads nothing. Its first `embed(texts:)` call acquires the model from
the pool, one time only, also when first calls run at the same time. The pool
is `ModelPool.shared` when you give no `pool:`. Two embedders of one name share
one resident model. All copies of one embedder share one hold, so the model
stays resident while a copy exists, and the pool evicts the model after the
last copy of the last embedder goes. After a failed load, the next call loads
again.

`PooledEmbedding` is the one interface of each embedder: `PooledEmbedder`
conforms to it, and so does the container of a loader. Its only requirement is
`embed(texts:)`. It has no `dimension`: each vector carries its length, so a
caller does not need a dimension before the first call.

Each `embed(texts:)` call is one job in the queue of the model. The embedder
uses the container only through `PooledEmbedding`, so the container of the first
loader works for all callers. When the container does not conform,
`embed(texts:)` throws `PooledEmbedderError.notAnEmbedding`:

```swift
// Loads nothing now. The first call loads the model into the pool.
let embedder = PooledEmbedder(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", pool: pool)
let vectors = try await embedder.embed(texts: ["save my work"])
```

`PooledEmbedder(hold:)` stays, for a caller that acquires the model with its
own byte counts. It throws `PooledEmbedderError.notAnEmbedding` at once when
the container of the hold does not conform.

This example is mirrored in `readmeEmbedderExample` in
`Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift`, kept
green by `swift test --filter PooledEmbedderTests`. The test declares `pool` (a
`ModelPool(loader:)` with a test loader) before the block.

### An LLM by name as a `LanguageModel`: `PooledModel`

`PooledModel(ref: "<Hugging Face name>")` makes a model of an LLM and loads
nothing. The pool is `ModelPool.shared` when you give no `pool:`. A
`PooledModel` is a FoundationModels `LanguageModel`, so you give it to a
`LanguageModelSession` as you give any other model. You need no type of this
package after that line.

The first generation call acquires the model from the pool with a key of the
`.llm` role, one time only, also when first calls run at the same time. All
copies of one `PooledModel` share that one hold, and each session keeps a copy.
Thus the model stays resident while a session or a copy exists, and the pool
evicts the model after the last one goes. After a failed load, the next call
loads again. Each generation call is one job in the queue of the model, so the
calls of all users of one model run one at a time, first in first out. A call
throws the error of the load, or `PooledSessionError.notALanguageModel` when
the container of the model is not a FoundationModels `LanguageModel`.

A session reads the capabilities of its model before the model loads. Thus
`capabilities:` of the initializer gives them. The default is guided
generation, tool calls and reasoning: the capabilities of each LLM that
`MLXModelLoader` gives. Give other capabilities when your loader gives a model
that can do less.

```swift
// Loads nothing now. The first respond call loads the model into the pool.
let qwen = PooledModel(ref: "mlx-community/Qwen3-4B-4bit", pool: pool)
let session = LanguageModelSession(model: qwen, instructions: "Answer with one number.")
let typed = try await session.respond(to: "How many legs has a cat?", generating: Answer.self).content
```

This example is mirrored in `readmeLanguageModelSessionExample` in
`Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`, kept green
by `swift test --filter PooledModelTests`. The test declares `pool` (a
`ModelPool(loader:)` with a test loader that gives a stub `LanguageModel`) and
`Answer` (a `@Generable` type) before the block.

### Sessions that fork: `PooledSession`

Use a `PooledSession` when you must fork a transcript. Each
`session(instructions:tools:)` call of a `PooledModel` acquires the model from
the pool with a key of the `.llm` role: the pool loads the model one time for
each name, also when
first calls run at the same time or come from two `PooledModel` values of one
name, and gives one hold to each session. The call throws the error of the
load, or `PooledSessionError.notALanguageModel` when the container of the model
is not a FoundationModels `LanguageModel`.

A `PooledSession` is a FoundationModels `LanguageModelSession` over the
`LanguageModel` of its hold. `model` is the Hugging Face name of the model.
`respond(to:)` gives the text of the answer, and `respond(to:generating:)`
decodes the answer as a `Generable` type. Each respond call is one job in the
queue of the model, so the calls of all sessions of one model run one at a
time, first in first out. A tool that the model calls in a respond call must
not wait for a respond call of a session of the same model: the queue refuses
that call with `GenerationQueueError.waitInsideOpenSubmission`.

`fork()` makes a new session that continues the transcript of its parent, with
the same tools and its own hold. The fork reads the transcript as one job in
the queue, so it waits for a respond call that runs. A later turn of one
session does not change the transcript of the other. The model stays resident
while a session or a fork exists, and the pool evicts the model after the last
one goes:

```swift
// Loads nothing now. The first session loads the model into the pool.
let qwen = PooledModel(ref: "mlx-community/Qwen3-4B-4bit", pool: pool)
let session = try await qwen.session(instructions: "Answer with one number.")
let text = try await session.respond(to: "How many legs has a cat?")
let typed = try await session.respond(to: "And a spider?", generating: Answer.self)
let child = try await session.fork()   // continues the transcript, with its own hold
```

The loader of a test can return any FoundationModels `LanguageModel` for an
`.llm` key, so a different package can test with a stub model and
`ModelPool(loader:)`.

This example is mirrored in `readmePooledModelExample` in
`Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`, kept green
by `swift test --filter PooledModelTests`. The test declares `pool` (a
`ModelPool(loader:)` with a test loader that gives a stub `LanguageModel`) and
`Answer` (a `@Generable` type) before the block. The integration tests in
`IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledModelIntegrationTests.swift`
use the real `mlx-community/Qwen3-4B-4bit`.

## Posting to a session: `Mailbox`

A `Mailbox<Message, Answer>` lets a caller post messages to a session and not
wait. The messages wait in first-in, first-out order. The session has one pump,
which takes the messages in batches and gives each message the answer of its
batch.

- `post(_:)` returns at once, with a `MessageID` and a `MailboxAnswer`. Read
  `answer.value` later. `postAndWait(_:)` posts and waits in one call, and a
  cancel of its caller cancels the message.
- `cancel(_:)` withdraws a message that waits (`.withdrawn`). A message in the
  running batch gets `CancellationError` at once (`.cancelledInSubmission`);
  the owner of the pump can then stop the batch. A message that has its answer
  gives `.alreadyAnswered`.
- `replace(_:with:)` changes a message that waits, and it keeps its place
  (`.applied`). After the pump took the message, the result is `.alreadySent`.
- `pending` gives the messages that wait, and `depth` counts them and names
  the messages of the running batch.
- The pump calls `answerNextBatch(joining:_:)` in a loop. The first waiting
  message starts a batch, and each later message that `joining` accepts comes
  with it. The result of the body goes to each message of the batch, also when
  the body throws or the pump is cancelled.

Each message gets exactly one result: its answer, the error of its batch, or
`CancellationError`. No message is lost. A mailbox that is released gives
`CancellationError` to each message that still waits:

```swift
let mailbox = Mailbox<String, String>()

// The one pump takes each batch. Each message of the batch gets the
// answer of the batch.
let pump = Task {
    while await mailbox.answerNextBatch({ letters in
        "read " + letters.map(\.message).joined(separator: " and ")
    }) {}
}

// Post a message, and read its answer later.
let (id, answer) = mailbox.post("hello")

// Or post, and wait for the answer in one call. A cancel of the
// caller cancels the message.
let reply = try await mailbox.postAndWait("how are you?")

// A message that waits can change (`replace`) or leave (`cancel`).
// The result tells what occurred: here the message has its answer.
let result = mailbox.cancel(id)
let greeting = try await answer.value
pump.cancel()
```

This example is mirrored in `readmeMailboxExample` in
`Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift`, kept green by
`swift test --filter MailboxTests`.

## Tool hosting: `ToolContext` and `RunPlane`

Tool hosting runs the tools of a session. A tool runs to completion, or it
runs in the background while the model continues. Each session has one
`RunPlane`: an actor that holds the background runs of the session and the
questions that those runs ask the user.

- `ToolMounting.makeWrapped(tool:site:configuration:)` mounts a tool on a
  `MountSite`: the session, its run plane and the sink of its events. A
  `String` tool runs to completion or in the background. The mount that the
  tool declares wins over the mount of the site.
- `ToolContext.current` is the context of the running call. A tool uses it to
  post events (`post(_:)`, `progress(_:)`), send mail to the calling session
  while the run continues (`message(_:)`, a `.message` event that is never
  terminal), attach records (`attach(_:)`), ask the user (`elicit(_:)`), read the background runs (`backgroundRuns()`), wait
  for a run (`wait(completionToken:seconds:)`), stop a run
  (`cancel(completionToken:)`), and mount a tool of its own (`mount(_:op:as:)`).
  A background call of a tool that `mount(_:op:as:)` mounted is a full
  background run: its terminal goes to the sink of the session under its own
  completion token, the same as a top-level background run.
- `BackgroundTool` lets a tool declare its mount (a `ToolMount`: run to
  completion or in the background, with a timeout or none), a timeout for one
  call, a short wait for its own result, the sentences for the model, and a
  canceler. A background
  call answers at once with a `PendingRunEnvelope`: the completion token of
  the run, and what the model must do next.
- `BackgroundTool.mount(for:)` gives the mount of one call, from its
  arguments. The host asks for it before each call, and it wins over the
  mount of the tool and the mount of the site. Thus one tool can start a run
  in the background for one operation, and give the real result in band for
  another operation (for example `list`, `check` or `cancel`). The default
  gives `mount`, the same for each call.
- An `OperationTool` of the `Operations` module is a `BackgroundTool`. Each
  operation declares its mount (`@Operation(..., mount: ToolMount(mode:
  .background))`), and the default is `ToolMount.synchronous`. The tool gives
  the mount of the called operation for each call. An unknown operation is
  synchronous. See [`docs/GUIDE.md`](docs/GUIDE.md).
- `SubmissionBoundaryTool` gets a call before each submission of the session.
  `ToolDecorator` passes that call down to the tool beneath a decorator.
- `ToolFailureDelivery.makeWrapped(tool:)` gives a failed call to the model as
  text. Only a cancellation throws.
- The host gives the answers of the user with `respond(elicitationId:_:)` and
  `complete(elicitationId:)`. At the end of the session, `sweep()` stops each
  run that is still open.

```swift
/// Runs the tests in the background. A call answers at once with a pending
/// envelope, and the model collects the result later.
struct RunTests: Tool, BackgroundTool {
    let name = "run_tests"
    let description = "Runs the tests of the package."

    @Generable
    struct Arguments {
        let filter: String
    }

    var mount: ToolMount? { ToolMount(mode: .background) }

    func call(arguments: Arguments) async throws -> String {
        await ToolContext.current?.progress("running \(arguments.filter)")
        return "all tests pass"
    }
}

/// Waits for a background run, with the completion token of its envelope.
struct Wait: Tool {
    static let waitSeconds: Double = 30

    let name = "wait"
    let description = "Waits for a background run."

    @Generable
    struct Arguments {
        let completionToken: String
    }

    func call(arguments: Arguments) async throws -> String {
        let outcome = await ToolContext.current?.wait(completionToken: arguments.completionToken, seconds: Self.waitSeconds)
        guard case .settled(let terminal) = outcome else { return "The run continues." }
        return terminal.detail
    }
}

// The host mounts each tool on the run plane of its session. `sink`
// gets each event of each run.
let runPlane = RunPlane()
let site = MountSite(sessionID: ULID(), runPlane: runPlane, sink: sink)
func mounted(_ tool: any Tool) -> any Tool {
    ToolFailureDelivery.makeWrapped(
        tool: ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous))
}
let tools = [mounted(RunTests()), mounted(Wait())]
// Give `tools` to the model session: `LanguageModelSession(tools: tools)`.

// At the end of the session, the sweep stops each run that is still open.
let swept = await runPlane.sweep()
```

This example is mirrored in `readmeBackgroundToolExample` in
`Tests/FoundationModelsExtrasTests/Hosting/ToolHostingReadmeTests.swift`, kept
green by `swift test --filter ToolHostingReadmeTests`.

## Tests

```sh
swift test                                   # unit tests
swift test --package-path IntegrationTests   # real MLX models
```

The real-model tests are a separate package in `IntegrationTests/`, so
`swift test` at the root loads no real model. The tests download small models
from the Hugging Face hub on the first run. The model ids are in
`IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/IntegrationModels.swift`.

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
