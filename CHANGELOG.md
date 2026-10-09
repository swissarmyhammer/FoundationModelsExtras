# Changelog

Each change to the public API of this package is recorded here. The newest
change is at the top.

## Unreleased

### Changed (breaking): no catalog version and no catalog display id

The store reads no catalog file, thus no install gives a catalog version or
a catalog `name`. The fields that held them are removed.

**What changed.**

- `MarketplaceProvenance.catalogVersion` is removed, and
  `MarketplaceProvenance.init(id:url:sha:)` has no `catalogVersion`
  parameter. `displayText` is always the id and the short commit, for
  example `skills@1a2b3c4`, or the id alone before the first install. It
  never shows `<id>@<catalog version>`.
- `MarketplaceListing.catalogVersion` is removed, and
  `MarketplaceListing.init` has no `catalogVersion` parameter.
- `MarketplaceListing.id` and `MarketplaceProvenance.id` are always the
  pre-fetch key: the alias of the source, else the repository name. Before,
  a `name` that an earlier version wrote into `state.json` named the
  marketplace until the next install. Now that `name` has no effect.
- `pin(_:sha:)`, `unpin(_:)` and `update(_:force:)` find a marketplace by
  its pre-fetch key only.
- `state.json` has no `catalogVersion` and no `displayID` key, in the record
  of a marketplace and in its `pending` snapshot. A state file that an
  earlier version wrote still loads: the store ignores the two keys, and the
  next write of the file drops them.

**Migration.** Remove each read of `catalogVersion`. A list that showed a
catalog version column shows the commit (`currentSha`) instead. A host that
named a marketplace by its catalog `name` names it by its alias: set
`alias` on the source to keep the same name. No change to `state.json` is
necessary.

### Changed (breaking): a marketplace is a folder scan, and an agent is a folder (`agents/<name>/AGENT.md`)

A marketplace is only a folder. The `Marketplace` product finds the skills
and the agents of a tree by a scan, and it reads no catalog file.

**What changed.**

- The store reads no `.claude-plugin/marketplace.json` and no
  `.agents/plugins/marketplace.json`. A catalog file in a tree has no
  effect: its plugins, its `skills` and `agents` lists, its `renames` and
  its remote plugin sources are not read.
- The scan has no depth limit. Before, a scan stopped at three path
  components. Now `plugins/<name>/skills/<skill>/SKILL.md` loads.
- A folder that holds the document of the layout (`SKILL.md`) is a skill,
  and a folder that holds `AGENT.md` is an agent. The folder name is the
  name. The scan does not read into a skill folder or an agent folder.
- `MarketplaceLayer.agentDocumentName` is new: `AGENT.md`.
- An agent is a folder. The snapshot holds `agents/<name>/AGENT.md` and the
  other files of the agent folder, copied as a tree with the same limits and
  link rules as a skill folder. Before, the snapshot held
  `agents/<file name>.md`.
- An `.md` file directly in a folder named `agents` (the old layout) does
  not load. It gives one diagnostic that tells where to move it.
- A folder that holds both `SKILL.md` and `AGENT.md` gives one diagnostic,
  and it is neither a skill nor an agent.
- When two skills, or two agents, have the same name, the shallower one
  wins; at the same depth, the first in path order wins. Each one that loses
  gives one diagnostic. Before, the later plugin of a catalog won.
- `SkillSelection.plugins(_:)` is removed. A `select` value of the form
  `plugins: [...]` does not decode. `SkillSelection.all` takes every skill
  and every agent; `SkillSelection.skills(_:)` takes no agent.
- The partials of a snapshot come from each folder from the root of the tree
  down to each selected skill and each agent. At the same level, the later
  folder in path order wins.
- The display id of a fetched marketplace is the pre-fetch key (the alias,
  else the repository name), and `catalogVersion` of a new install is `nil`.
  The store no longer gives the diagnostic for two sources with the same
  catalog `name`.

**Migration.** Move each agent file `agents/<id>.md` to
`agents/<id>/AGENT.md`. Remove the catalog files, or keep them for other
tools; this package ignores them. Replace `select: { plugins: [...] }` with
`select: { skills: [...] }`, or with `all`. A tree that needs a skill from a
deep folder needs no change.

### Added: `ToolContext.emit(chunk:)` and `ToolContext.update(title:kind:locations:)`

A tool can now send its display output and its metadata with one short call.
Before, a tool had to make a `ToolDisplayEvent.Kind` and give it to
`post(display:)`.

**What changed.**

- `ToolContext.emit(chunk:)` is new. It posts a `.contentChunk` display event
  with the `ToolDisplayContent` that it gets.
- `ToolContext.update(title:kind:locations:)` is new. It posts a `.metadata`
  display event with no `rawInput`. Each argument is optional, and a `nil`
  argument does not change the value that the client has.
- Both helpers work in each runner path: a tool whose output is not `String`
  (`ContextBindingTool`), a synchronous call (`RunToCompletionRunner`) and a
  background call (`BackgroundToolRunner`). A background run sends them also
  after its settle period, under its own completion token.
- A display event now counts as a sign of life for the timeout of the run,
  the same as progress and a message. A tool that sends output to the client
  is alive. Before, a run that sent only display events timed out.
- A background run that answers in its settle period does not withdraw its
  display events. `StagedEventWithdrawing.withdrawStagedEvents(correlationID:)`
  applies only to the operation events that the sink staged for the model.
  The model never reads a display event, and the runner delivers each display
  event before the withdraw, so the client already shows it.

**Migration.** No change is necessary. A tool can use the helpers in place of
`post(display:)`. A tool with a timeout that sends display events and no
progress now runs past the timeout while it sends them.

### Added: a display-only event lane for tools (`ToolDisplayEvent`, `OperationEventSink.post(display:)`, `ToolContext.post(display:)`)

A tool can now send output and metadata of its call to the client of the
host, for example the ACP `tool_call_content_chunk` and `tool_call_update`
updates. Before, a tool had only `progress(_:plan:)`. A new progress event
replaces the earlier one, a host can combine progress events, and the host
puts the progress `detail` in the model input. Thus progress is not a
usable display stream.

**What changed.**

- `ToolDisplayContent` is new. It holds text (`.text`), a diff of one file
  (`.diff(path:oldText:newText:)`, where `oldText == nil` is a new file), or
  a JSON text (`.json`).
- `ToolDisplayEvent` is new. It has a `tool`, an `op`, a `correlationID` (the
  completion token of the run) and a `kind`:
  - `.contentChunk(ToolDisplayContent)` adds one part of the output.
  - `.contentReplace([ToolDisplayContent])` replaces the full output.
  - `.metadata(title:kind:locations:rawInput:)` sets new metadata of the
    call. A `nil` field does not change the value that the client has.
    `ToolDisplayEvent.ToolKind` has the ACP tool kinds (the wire value of
    `switchMode` is `"switch_mode"`), and `ToolDisplayEvent.Location` has a
    `path` and an optional `line`.
- `OperationEventSink.post(display:)` is new. Its default implementation does
  nothing, the same as `post(invocation:)`.
- `ToolContext.post(display:)` is new. It stamps the kind with the `tool`, the
  `op` and the `completionToken` of the run, the same as each other event.
- A display event never goes into the model input. It is not an
  `OperationEvent`, so it never changes the progress detail of a run, and the
  run event funnel does not count it as an event of the run for the terminal
  event. It counts as a sign of life for the timeout of the run (see the next
  entry).
- A display event is never combined with another display event, and a host
  never records it in the journal. The type is not `Codable`.
- A synchronous call that `ToolContext.mount(_:op:as:)` mounts sends each
  display event again under the stamps of the mounting run.

**Migration.** No change is necessary. A host that wants the display events
must implement `post(display:)` on its sink, and send each event to its
client without a change.

### Changed (breaking): a background call answers with its own result when the run ends inside the settle period

The rule is now: a background call goes to the background only when its run
takes longer than the settle period.

**Cause.** Before, a background call answered at once with a pending
envelope, unless the tool declared `inlineSettleGrace`. A run that ended
inside that grace answered with a settled envelope (`pending: false`, with
`outcome` and `detail`). Thus the model got a different shape for a short run
of a background tool than for a synchronous tool, and it had to read the
result from the `detail` field.

**What changed.**

- `ToolMount.defaultInlineSettleGrace` is new: 6 seconds. It is the only
  constant for the settle period.
- `MountSite.init(sessionID:runPlane:sink:op:tracer:inlineSettleGrace:)` has
  a new last parameter, `inlineSettleGrace`, with the default
  `ToolMount.defaultInlineSettleGrace`. It is the setting of the host. A
  negative value acts as `0`. `0` answers with the pending envelope at once.
- `BackgroundTool.inlineSettleGrace` is now a `TimeInterval`, not a
  `TimeInterval?`. The default gives the settle period of the mount site. A
  tool that states its own value wins over the site.
- A background call waits for its run up to the settle period. A run that
  ends in that time answers with its own result, the same as a synchronous
  call: the output of the tool, or the error that the tool threw. The sink
  takes back the staged events of that run (`StagedEventWithdrawing`). The
  run plane still holds the terminal event of the run.
- Only a run that continues past the settle period answers with a
  `PendingRunEnvelope`. The run settles later with one terminal event.
- `PendingRunEnvelope` is always pending. Its wire form has only `pending`
  (always `true`), `completionToken` and `next`.
  `PendingRunEnvelope.makeDecoded(fromRendered:)` and `isRendered(text:)` do
  not recognize a text with `"pending":false`.
- `ToolContext.inlineSettleGrace` is new: the settle period of each tool that
  the context mounts. `ToolContext.init` has a new last parameter,
  `inlineSettleGrace`, with the default `ToolMount.defaultInlineSettleGrace`.
  `ToolContext.settling(within:)` is new: it gives a copy of the context with
  a different settle period for its inner mounts.
- An inner background call that a run makes inside its own settle period
  stops its wait 1 second before the end of that period. Thus the outer run
  has time to use the result. When the period of the outer run has ended, the
  inner call waits for its full settle period.

**Removed.**

- `PendingRunEnvelope.outcome` and `PendingRunEnvelope.detail`.
- `PendingRunEnvelope.replacing(detail:)`.
- `PendingRunEnvelope.defaultResultInstruction(forCompletionToken:)`.
- `BackgroundTool.resultInstruction(forCompletionToken:)` and its default.
- The settled envelope (`pending: false`).

**Migration.**

- A tool that declared `var inlineSettleGrace: TimeInterval? { nil }` to
  answer at once must now declare `var inlineSettleGrace: TimeInterval { 0 }`,
  or the host must give `inlineSettleGrace: 0` to its `MountSite`.
- A tool that declared a grace as `TimeInterval?` must change the type to
  `TimeInterval`.
- Remove each `resultInstruction(forCompletionToken:)` of a tool.
- A host or a layer that read `detail` or `outcome` of a settled envelope, or
  that called `replacing(detail:)`, must now read the output of the call as
  the output of a synchronous call. A thrown error of a short run now comes
  back as a thrown error of the call.
- A test that needs a pending envelope from a fast tool must give
  `inlineSettleGrace: 0` to the site, or keep the run open with a gate.

### Added: `PlanSnapshot`, `OperationEvent.plan` and `ToolContext.progress(_:plan:)`

A tool can now send its agent plan to the host. The plan is a copy of the ACP
agent plan (https://agentclientprotocol.com/protocol/v2/agent-plan). It goes
one way only: the host sends it to the client, and the model never gets it.
`detail` stays a short text line for the model, because the host puts
`detail` in the model text.

**What changed.**

- `PlanSnapshot` is new. It has an `id` and the full list of its `entries`.
  An update replaces the plan that has the same `id`. Each
  `PlanSnapshot.Entry` has a `content`, a `priority` (`high`, `medium`,
  `low`) and a `status` (`pending`, `inProgress`, `completed`, `cancelled`).
  The wire value of `inProgress` is `"in_progress"`, the same as ACP.
- `OperationEvent.plan` is new. It is non-nil only when `kind == .progress`.
  `OperationEvent.init` has a new last parameter, `plan: PlanSnapshot? = nil`.
- `ToolContext.progress(_ detail: String, plan: PlanSnapshot? = nil) async`
  posts a `.progress` event with the plan. A call with no plan posts the same
  event as before.
- `ToolContext.post(_:)` keeps the `plan` of the event.
- An event that was recorded before this change decodes with `plan == nil`.

**Migration.** No change is necessary. A host that wants the plan must send
the `plan` of each `.progress` event to its client, and must keep it out of
the model text.

### Added: `OperationEventKind.message` and `ToolContext.message(_:)`

A run, for example the body of a background run, can now send mail to the
session that called it, while the run continues. The session can be a parent
run or the root session of the host. A `.progress` event starts no answer in
a host, and a `.completed` event ends the call, thus neither can carry mail.

**What changed.**

- `OperationEventKind.message` is new. Its wire value is `"message"`. It is
  never terminal. `OperationEvent.detail` holds the text of the message, and
  `OperationEvent.outcome` is `nil`.
- `ToolContext.message(_ text: String) async` posts a `.message` event with
  `text` as its detail, stamped with the `tool`, the `op` and the
  `completionToken` of the run, as `progress(_:)` does.
- A message counts as a sign of life for the timeout of the run, the same as
  progress. It does not change the latest progress detail on the run plane.
- A message that a run posts after its terminal event is dropped, the same
  as a second terminal event, because no call waits for it.
- An event that was recorded before this change decodes unchanged.

**Migration.** A `switch` over `OperationEventKind` in a consumer must add the
`.message` case. A host that wants the mail must deliver each `.message` event
to the session of its `correlationID`.

### Added: `PooledModel` is a FoundationModels `LanguageModel`

A caller can now give a `PooledModel` to a `LanguageModelSession`, for example
`LanguageModelSession(model: PooledModel(ref: "mlx-community/Qwen3-4B-4bit"), instructions: ...)`.
Guided generation, tool calls and reasoning then go through the pooled model.
A package that uses the pool thus needs no protocol or session type of its
own over FoundationModels.

**What changed.**

- `PooledModel` conforms to `LanguageModel`. Its executor is the new public
  `PooledModelExecutor`.
- The first generation call acquires the model from the pool, one time only,
  also when first calls run at the same time. `init` loads nothing. All copies
  of one `PooledModel` share that one hold, thus the model stays resident while
  a session or a copy exists. After a failed load, the next call loads again.
- Each generation call is one job in the `GenerationQueue` of the model. The
  call runs the executor of the loaded container, which the pooled model makes
  one time from the `executorConfiguration` of the container.
- `prewarm` of a session starts the load, and then prewarms the loaded model.
- `PooledModel.init(ref:pool:capabilities:)` has a new `capabilities`
  parameter, because a session reads the capabilities before the model loads.
  The default is guided generation, tool calls and reasoning: the capabilities
  of each LLM that `MLXModelLoader` gives. A call of `init(ref:pool:)` compiles
  with no change.
- `PooledModel.session(instructions:tools:)` and `PooledSession` do not
  change. Use them when you must fork a transcript.

### Changed (breaking): `PooledEmbedding` has no `dimension`, and `PooledEmbedder` conforms to `PooledEmbedding`

`PooledEmbedding` is now the one interface of each embedder. Its only
requirement is `embed(texts:)`. `PooledEmbedder` conforms to it, thus a caller
can keep an `any PooledEmbedding` and not know if a pool holds the model.

**What changed.**

- `PooledEmbedding` has no `dimension` property. `PooledEmbedder` cannot give
  a dimension before the model loads. Each vector carries its length, so a
  caller that needs the dimension reads the length of a vector.
- The container that `MLXModelLoader` gives for the `.embedding` role no longer
  does a probe embed call when it loads.

**Migration.** Remove `dimension` from each type that conforms to
`PooledEmbedding`. In place of `embedding.dimension`, use the `count` of a
vector that `embed(texts:)` gives.

### Fixed: the terminal event of a call that `ToolContext.mount(_:op:as:)` mounted no longer takes the place of the terminal event of the mounting run

A synchronous call that `ToolContext.mount(_:op:as:)` mounted now sends its
terminal event to the mounting run as a `.progress` event with the same
detail. The mounting run then gives its own terminal event, as before.

**Cause.** The sink of the mount sent each event of the mounted run through
`ToolContext.post(_:)` of the mounting context, and a `.completed` event
stayed `.completed`. The funnel of the mounting run took that event as its
one terminal event, and dropped the real terminal event of the mounting run
when the run settled. Thus the session sink got the outcome and the detail of
the inner call in place of those of the mounting run. For example, a script
runner whose snippet caught the error of an inner call and returned a value
gave a `.failed` terminal event with the error of the inner call. An inner
call that posted progress and succeeded also put its own result in place of
the result of the mounting run.

**What changed.**

- The session sink gets exactly one terminal event for the mounting run: the
  terminal event that the run plane also keeps.
- The end of each mounted call that posts a terminal event is now a progress
  event of the mounting run. Thus it starts a new timeout window of the
  mounting run, as each other progress event does.

### Changed (breaking): `TracedCall.run` records the error type on the span, never the error description

When the body of `TracedCall.run` throws, the span now gets the error status
and an `error.type` attribute. The span records no error event, no status
message and no description of the error. Each mounted tool call goes through
`TracedCall.run` (by way of the tool span), thus the same holds for the error
of a tool.

**Cause.** `TracedCall.run` opened its span with `withSpan`, and `withSpan`
records each error that it sees with `span.recordError(error)`. swift-otel
exports that error as an `exception` event with
`exception.message = String(describing: error)`. The description of an error
can hold content: a path, a part of a prompt or a tool argument. Thus that
content went to the telemetry backend. A rule in a doc comment does not
protect the telemetry.

**What changed.**

- The value of `error.type` is the full type name of the error, for example
  `MyModule.LoadError`. For an enum case with a payload, the case name
  follows, for example `MyModule.LoadError.missing`. Reflection shows no case
  name for an enum case with no payload, thus that value is the type name
  only. The value of a `CustomReflectable` error is the type name only,
  because a custom mirror can put a payload in the label of a child. The
  value never holds the payload.
- A span of `TracedCall.run` has no recorded error. A consumer test that reads
  the `errors` of such a span must read the status and `error.type` in place
  of them.
- A body can now throw an error whose description holds content. The
  content-safety tests of `TracedCall` and of a tool that throws such an error
  prove that no span, log record or metric holds it.

### Changed (breaking): `TelemetryCapture` reads the span links, the span events, the recorded errors, the span status message and the log record errors

A forbidden string in an attribute of a span link, in the name or an attribute
of a span event, in the description or an attribute of an error that a span
records, in the status message of a span, or in the description of the error
of a log record, is now an issue of `TelemetryCapture.run(forbidding:)`.

**Behavior change.** A consumer test that throws an error whose description
holds a forbidden string through `withSpan`, the helper of
swift-distributed-tracing, inside `TelemetryCapture.run(forbidding:)`, now
records an issue at `spanError`. The same test passed before. A consumer test
that logs such an error with `error:` now records an issue at `logError`.
`TracedCall.run` records no error on its span (see the entry above), thus an
error that it throws gives no issue at `spanError`.

**Cause.** The capture read only the name and the attributes of each span, and
only the message and the metadata of each log record. swift-otel exports
`span.recordError(error)` as an `exception` event with
`exception.message = String(describing: error)`, and `withSpan`, the helper of
swift-distributed-tracing, records each error that it sees. `TracedCall.run`
records no error (see the entry above). A log handler writes the error of a
log record. Thus an error description that held content went to the
telemetry backend, and no content-safety test that used the capture found it.

**What changed.**

- New `TelemetryPlace` cases: `spanLinkAttribute(span:key:value:)`,
  `spanEventName(span:event:)`, `spanEventAttribute(span:event:key:value:)`,
  `spanError(span:description:)`, `spanErrorAttribute(span:key:value:)`,
  `spanStatusMessage(span:message:)` and `logError(level:description:)`. The
  description of `spanError` and of `logError` is `String(describing:)` of the
  error. A `switch` over `TelemetryPlace` in a consumer must add the new cases.
- `TelemetryCapture.Context.places` gives, for each span: the name, the
  attributes, the attributes of each link, the name and the attributes of each
  event, the description and the attributes of each recorded error, then the
  status message when the status has one. For each log record it gives the
  message, the description of the error when the record has one, then the
  metadata.

### Changed (breaking): each log record of `TelemetryCapture` keeps the label of its logger

`TelemetryCapture.Context.logRecords` is now `[TelemetryCapture.LogRecord]`.
It was `[InMemoryLogHandler.Entry]`. The new public struct
`TelemetryCapture.LogRecord` has `level`, `message`, `error`, `metadata` and
`label`, and it is `Equatable` and `Sendable`. `label` is the label of the
logger that wrote the record: the label of a new `Logger(label:)`, or
`TelemetryCapture.loggerLabel` for `Context.logger`. A test can thus check
that each record of a package has a label with the module name as a prefix.

**Cause.** swift-log's `InMemoryLogHandler.Entry` has no label, and a package
cannot add a stored property to it. Thus a test could not check the label of
a record.

**Migration.** Code that reads `.level`, `.message`, `.error`, `.metadata` or
`.count`, or that compares two arrays of records, does not change. Code that
names `InMemoryLogHandler.Entry` must name `TelemetryCapture.LogRecord`: for
example `[InMemoryLogHandler.Entry]` becomes `[TelemetryCapture.LogRecord]`,
and `extension InMemoryLogHandler.Entry` becomes
`extension TelemetryCapture.LogRecord`. An expected record that the test makes
also needs the label:
`TelemetryCapture.LogRecord(level:message:error:metadata:label:)`. Two records
are equal only when their labels are equal too.

### Added: `MLXModelLoader(tokenizerLoader:)`

`MLXModelLoader` now takes an optional `TokenizerLoader`, and loads the
tokenizer of each model, an LLM or an embedding model, with it. `nil`, the
default, uses the Hugging Face tokenizer loader, thus `MLXModelLoader()` loads
as before. A caller that loads the chat template with a pinned date thus needs
no `MLXLanguageModel` of its own.

### Changed (breaking): a download value of `ModelLoadProgress` has real byte counts

`ModelLoadProgress.downloading(fraction:)` is now
`downloading(completedBytes:totalBytes:)`, and the new `fraction` property
gives `completedBytes` over `totalBytes` for a download value (`nil` for the
other values). `MLXModelLoader` reports the completed bytes and the total bytes
of the files of the repository that the Hugging Face downloader gives, and all
the bytes when the download ends. A model that the Hugging Face cache holds at
a pinned commit gives no download value, because nothing downloads.
`ModelPool.progress(for:)` drops a download value with fewer completed bytes
than the download value before it, thus `completedBytes` does not decrease in a
stream.

**Migration.** Replace `case .downloading(let fraction)` with
`case .downloading(let completedBytes, let totalBytes)`, or read
`progress.fraction`. A loader that reports a download gives the real byte
counts. Each acquire method of the pool gives the progress of its load to
`progress(for:)`; a loader that implements only `load(_:)` reports only
`loading`, thus implement `load(key:progressHandler:)` to report a download.

### Fixed: an MLX embedding model gives the same vector for a text in a batch and for the text alone

`embed(texts:)` of a `PooledEmbedder` over `MLXModelLoader` now gives each text
of a batch the vector of the same text embedded alone (cosine ≥ 0.999). Before,
each text that was shorter than the longest text of the batch got a wrong
vector: the FoundationModelsRouter measured cosines of 0.438 and 0.275.

**Cause.** The pooling got no mask, thus `.last` pooling (the Qwen3 embedders)
read the hidden state of a pad token for each short text. The model mask was
`token != padToken`, and the pad token is the end token, thus that mask also
removed the real end token of each text. Now the mask of each row comes from
its length (1 for each real token, the end token included, and 0 for each pad),
and the model and the pooling both get it.

### Fixed: `ModelPool` counts an evicted model until the evict call of its loader returns

`footprint`, each value of `footprints`, `isResident(_:)` and
`residentModelCount` now show an evicted model until `evict` of its loader
returns. While that call runs, the model gives no hold: an `acquire` of its
key loads the model again after the eviction job.

**Cause.** The eviction job removed the model from the pool state, and only
then called `evict`. A caller that read the footprint outside an admission job
saw the memory as free while the loader still freed it. On 2026-09-29, about
370 MB of the prompt cache of an `MLXLanguageModel` was still active when a
new `footprints` stream showed no LLM.

### Changed: the swift-distributed-tracing floor is 1.5.0

The manifest said `from: "1.4.1"`, but `TelemetryCapture.run` calls
`withTracer`, which starts in 1.5.0. A consumer that resolved 1.4.1 did not
build `TelemetryTestSupport` ("cannot find 'withTracer' in scope"). The
manifest now says `from: "1.5.0"`.

### Changed: `TelemetryCapture` uses a tracer that injects and extracts W3C `traceparent` and `tracestate`

In a capture, the "enter" record of `TracedCall` holds the `trace.id` and the
`span.id` of its span, and a test can prove that a `traceparent` value goes
across a process boundary, for example in the `_meta` of an ACP or MCP request.

**Cause.** The capture bound an `InMemoryTracer`. That tracer injects and
extracts only its own trace-id and span-id keys, and no W3C `traceparent`
value. Thus `SpanIdentity` found no ids, and no package could test rule 7 of
the OpenTelemetry design of 2026-09-28: the `traceparent` value goes across
each process boundary.

**What changed.**

- New in `TelemetryTestSupport`: `W3CInMemoryTracer`. It keeps its spans in an
  `InMemoryTracer` (`inMemoryTracer`, `finishedSpans`, `activeSpans`), with ids
  in the W3C format. `inject` writes `traceparent`
  (`00-<trace id>-<span id>-<flags>`) and `tracestate` when the context has one.
  `extract` reads `traceparent` and `tracestate`, ignores a value that the W3C
  format does not allow, and puts the remote span context into the
  `ServiceContext`, so that the next span is a child in the same trace.
  `injectedFields(of:)` and `extractedContext(from:)` do the same with a
  `[String: String]` carrier. `ServiceContext.w3cTraceFlags` and
  `ServiceContext.w3cTraceState` hold the extracted flags and `tracestate`.
- `TelemetryCapture.Context.tracer` is now a `W3CInMemoryTracer`. It was an
  `InMemoryTracer`. `TelemetryCapture.run` binds it with `withTracer`.
- `SpanIdentity` is now public, in the core module. It is the one copy of the
  `traceparent` format: `init?(traceparent:)`, `init?(traceID:spanID:traceFlags:)`,
  `init?(context:tracer:)`, `traceparent`, `traceFlags`, `injectedFields(of:by:)`,
  and the carrier keys `traceparentField` and `tracestateField`.
- `TelemetryTestSupport` now depends on the `FoundationModelsExtras` module.

**Migration.** Code that gives `context.tracer` to an `any Tracer` parameter,
or reads `context.tracer.finishedSpans` or `context.spans`, needs no change.
Code that needs the `InMemoryTracer` type itself, for example to read
`performedContextInjections`, reads `context.tracer.inMemoryTracer`. A test that
expects the exact metadata of an "enter" record in a capture must now expect
the `trace.id` and the `span.id` too.

### Changed: the tool span is `FoundationModelsExtras.tool`, with an "enter" record and tool-call metrics

Each mounted tool call gives one span, one "enter" log record, one count and
one duration.

**Cause.** The OpenTelemetry design of 2026-09-28. Rule 3: each package keeps
its telemetry names in one vocabulary file, with the module name as the prefix.
Rule 8: a call that can suspend for a long time writes one log record when it
starts, so that a call that hangs shows in the logs.

**What changed.**

- The name of the tool span is now `FoundationModelsExtras.tool`. It was
  `FoundationModelsRouter.tool`. The attribute keys `tool.name`, `session.id`,
  `tool.run_kind` and `tool.outcome` do not change.
- Each tool call writes one `.info` log record, `enter FoundationModelsExtras.tool`,
  with the metadata `tool.name` and `session.id`, and the `trace.id` and
  `span.id` of the span when the tracer gives them.
- Each outcome of a tool call adds one count to the counter
  `FoundationModelsExtras.tool.calls` and one duration to the timer
  `FoundationModelsExtras.tool.duration`. Both metrics have the dimensions
  `tool.name` and `tool.outcome` only. For a background call, the duration
  measures the start of the run only, as the span does.

**Migration.** A dashboard or a query that reads the span
`FoundationModelsRouter.tool` must read `FoundationModelsExtras.tool`.

### Added: the `TelemetryTestSupport` product

A test target of each package of the family can prove that its telemetry
carries no content of the caller.

**Cause.** The OpenTelemetry design of 2026-09-28 has two rules. Rule 4: a span
attribute, a log message, a log metadata value and a metric dimension carry
ids, names, counts and sizes only, never a prompt, a response, tool arguments,
tool output, embed text or an LSP payload. Rule 5: each package proves rule 4
with a content-safety test that uses one shared helper.

**What changed.**

- `TelemetryCapture.run(forbidding:_:)` runs the code under test with an
  in-memory tracer, log handler and metrics factory. After the code, it
  records one issue for each place that contains a forbidden string. Each issue
  names the place, as `<span>.<key> = <value>`, `log <level>: <message>`,
  `log metadata <key> = <value>` or `metric <name> <key> = <value>`.
- `TelemetryCapture.Context` gives the tracer, the logger and the metrics
  factory of the capture, the recorded spans, log records and metrics, and
  `leaks(forbidding:)` for a test that inspects the result.
- The capture binds its tracer with `withTracer` and its metrics factory with
  `withMetricsFactory`, thus it calls no `InstrumentationSystem.bootstrap` and
  no `MetricsSystem.bootstrap`. It calls `LoggingSystem.bootstrap` one time for
  each process, with a handler that sends each record to the capture of its
  task. Captures that run in parallel do not see the records of each other.

**Migration.** Add
`.product(name: "TelemetryTestSupport", package: "FoundationModelsExtras")` to
the test target. A test process that uses the helper must not bootstrap the
logging system itself.

### Added: each operation declares its mount

An `OperationTool` now runs each call with the mount of the called operation.

**Cause.** One `OperationTool` holds several operations. Some operations must
start a background run (for example `start agent`), and other operations must
give their real result in band (for example `list agents`, `check agent` and
`cancel agent`). Before, the tool had one mount for all its operations.

**What changed.**

- `OperationDefinition.mount` is the `ToolMount` of an operation. The default
  is `ToolMount.synchronous`.
- `@Operation` takes a `mount` argument, for example
  `@Operation(verb: "start", noun: "agent", description: "...", mount: ToolMount(mode: .background))`.
  The macro emits the `mount` static only when the argument is present.
- `AnyOperation.mount` holds the mount of the erased operation.
- `OperationTool` conforms to `BackgroundTool`. `mount(for:)` gives the mount
  of the operation that the `op` of the call names. An unknown operation is
  synchronous, so its correction comes back in band.
- `Operations` re-exports `ToolMount` as a typealias, so code that imports only
  `Operations` can name it.

**Migration.** An `OperationTool` that a host mounts as background now runs
each call synchronously, unless the called operation declares a background
mount. Give `mount: ToolMount(mode: .background)` to each operation that must
run in the background.

### Added: `BackgroundTool.mount(for:)`

A tool now chooses background or synchronous for each call, not one time for
the whole tool.

**Cause.** The mount was read one time for each tool. A tool with some
operations that must start a background run and other operations that must
give their real result in band (for example `list`, `check` and `cancel`) had
to mount as background, and it could only hope that a fast operation settled
in `inlineSettleGrace`. That is a timeout, not a choice.

**What changed.**

- `BackgroundTool.mount(for:)` gives the mount of one call, from its
  arguments. The host asks for it before each call, and it wins over `mount`
  and over the mount of the host. The default gives `mount`, thus each tool
  that does not override it keeps its behavior.
- A synchronous call runs in band and returns its output. It does not wait
  for a grace. A background call returns the pending envelope, and the run
  plane tracks the run.
- A background call of a tool that `ToolContext.mount(_:op:as:)` mounted is a
  full background run: its terminal goes to the sink of the session under its
  own completion token, the same as a top-level background run. Before, it
  went through the mounting run, which took it as its own terminal or dropped
  it.

### Added: `DotfolderWatcher`

A consumer that caches a result of a stack can now watch the layer roots with
a type of this package.

**Cause.** `DotfolderStack` holds no cache, thus it needs no watcher of its
own, and its documentation sent each consumer to a watcher of its own. That
is against the rule of the family: the raw work of loading lives here, and a
consumer keeps the work of its own schema only. `FoundationModelsSkills`
carried such a watcher, with no skill semantics in it.

**What changed.**

- `DotfolderWatcher` is public. It watches the directory tree of each root
  recursively, and it joins a burst of file system events into one `onChange`
  call after a quiet period. It has no opinion about what changed: the
  consumer reads the stack again from the start.
- `init(roots:debounceInterval:onChange:)` takes the roots, and
  `init(stack:debounceInterval:onChange:)` takes the layer roots of any
  `DotfolderStacking`. The default quiet period is 200 ms.
- `start()` and `stop()` are the commands, and `deinit` stops the watcher.
  `stop()` closes each file descriptor, and it is safe to call from inside
  `onChange`. A watcher that stopped starts again.
- A root that is not on disk at `start()` is armed at its nearest existing
  ancestor, thus the later creation of that root fires `onChange` too. Work
  under that ancestor that does not bring the root nearer to existence fires
  nothing.
- The dependency budget does not move: the type needs Foundation and
  Dispatch.

### Added: `QuarantinedText` and `StenciledDotfolderStack.render(_:in:)`

A consumer can now render text that it holds itself, with the trust and the
partial scope of a layer.

**Cause.** `StenciledDotfolderStack` rendered only a file that it read
itself. Its trust rule, its partial scope rule, its context and its
well-known values were all private, thus a consumer that holds text of its
own had no supported way to render it. `FoundationModelsSkills` is such a
consumer: the body of a skill goes through two passes of the skill format
first, and the text that those passes splice in is data, which Stencil must
never scan. With no entry point here, Skills rebuilt the generic half
itself. That half is Stencil work, thus it belongs in this package.

**What changed.**

- `QuarantinedText` is public. It holds text in spans: an `.original` span
  is source text, which the next pass may scan, and a `.quarantined` span is
  text that an earlier pass spliced in, which each later pass copies and
  never scans. `init(spans:)` drops each empty span and joins the adjacent
  `.original` spans. `mappingOriginalSpans(_:)` and
  `mappingOriginalSpans(awaiting:)` are the one seam that a pass uses, and
  each `.original` span comes with the character before it in the joined
  text. `SpanBuilder` collects the spans of one pass.
- `StenciledDotfolderStack.render(_:in:)` renders such a text, and the
  convenience of the same name renders a plain `String`. The trust comes
  from the layer (`.defaults` is trusted, each other source is untrusted)
  and the scope of the partials comes from the layer as well. The whole text
  is ONE template: each quarantined span reaches Stencil as a context value,
  thus a `{{ … }}` or an `{% include %}` inside it stays as it is, and the
  text on the two sides of a span is still one template. One template means
  one render, thus one set of the untrusted limits, whatever the number of
  spans. A span inside an open `{{`, `{%` or `{#` throws
  `TemplateEngineError.renderingFailed`, and a bare `{` before a span stays
  literal.
- `WellKnownValues` is public, with a public initializer and a public
  `current(partials:)`, and `StenciledDotfolderStack.init` takes
  `wellKnownValues:`. `nil`, the default, reads the current values at each
  render, as before. A consumer that must pin `hostname`, `date` and
  `working_directory` gives them here.
- The environment stays out of this stack. A consumer that wants an
  environment value in its text puts that value in `variables`.

### Added: `DotfolderStack(layers:)` and the execute bit of the winning copy

`DotfolderStack` has a second initializer that takes an explicit list of
layers, and each stack of the family answers for the execute bit of the
winning copy.

**Cause.** `FoundationModelsSkills` held one shim for each gap: an internal
`init(layers:)` that called the derived initializer with a placeholder name
and then replaced the layers, and a direct read of `FileManager` for the
mode of a file. The rule of the family is that the raw work of loading lives
in Extras, thus both gaps close here.

**What changed.**

- `DotfolderStack.init(layers:)` is public. It stores the layers, lowest
  precedence first. It derives no layer, it applies no name rule, and it
  reads no file, the same as the derived initializer. A consumer that holds
  its own layers — a list of host directories, or the marketplace layers of
  a store below the local layers — makes a stack from them.
- The well-known template value `dotfolder_name` comes from the
  highest-precedence `.project` layer. A derived stack holds one `.project`
  layer, thus its value does not change. A stack from `init(layers:)` can
  hold more than one `.project` layer, and the last one names the stack. A
  stack with no `.project` layer has no name.
- `isExecutable(_:)` is a new requirement of `DotfolderStacking`, and
  `DotfolderStack`, `StenciledDotfolderStack` and `FrontmatterDocumentStack`
  each answer it. It reports the execute bit of the copy in the highest
  layer that holds the path, through the same path checks as `exists(_:)`:
  a path that is empty, absolute or that holds a `..` component, a copy that
  resolves through a symbolic link to a location outside its layer root, and
  a missing file each give `false`. A consumer that lists a file or that
  runs a script no longer needs `FileManager`.

**This change adds a requirement to a protocol.** A type outside this
package that conforms to `DotfolderStacking` does not compile until it adds
`isExecutable(_:)`. A stack that is layered over another stack passes the
call to its base.

### Added: the `Marketplace` product

`MarketplaceStore.init(sources:layout:cacheDirectory:policy:)` makes a store
over a source list, with no network work. `marketplaceLayers()` gives one
`MarketplaceLayer` for each source, lowest precedence first, from the disk
alone; `start()` brings each git source to its remote head one time;
`update(_:force:)`, `check()`, `pin(_:sha:)` and `unpin(_:)` are the
commands of a host; `events` and `layerUpdates` are the two streams. The
product is the separate `Marketplace` target, which carries libgit2 and
Yams; the core target does not change. The test doubles are the
`MarketplaceFixtures` product.

**Cause.** `FoundationModelsSkills` carried the whole marketplace: the git
transport, the catalog read, the cache, the snapshot writer, the store and
the config loader. Each of them reads files, and none of them knows what a
skill is. The decision of 2026-09-19 is that Extras owns all marketplace
file reading, thus the capability leaves Skills, and Skills reads a
materialized layer root the same way it reads a local layer. The one skill
fact of the old code, the name `SKILL.md`, became an input of
`MarketplaceLayout`.

**What changed.**

- `MarketplaceStore` is an actor that owns every marketplace of a host: the
  source list, the cache on the disk, and the layers that a consumer reads.
  `init(sources:layout:cacheDirectory:policy:)` reads only the disk;
  `cacheDirectory` has the default `cacheDirectory(environment:)`, which
  reads `SKILLS_MARKETPLACE_CACHE` and falls back to
  `~/.cache/skills/marketplaces`. A second initializer takes a `transport`,
  a `clock` and an `environment`, for a test. `start()` applies a pending
  snapshot and brings each git source to its remote head; `stop()` ends the
  periodic check; `check()` gives one `MarketplaceStatus` for each source
  and downloads nothing; `update(_:force:)` installs a new commit and gives
  the events of the pass; `pin(_:sha:)` and `unpin(_:)` hold or release one
  marketplace at one commit, and throw `MarketplacePinError`. `diagnostics`
  is the list of findings; no message holds a credential.
- `MarketplaceLayerProviding` is what a consumer needs from a store:
  `marketplaceLayers()`, lowest precedence first, and `layerUpdates`, one
  value for each change. A symlink swap sends no reliable file-system
  event, thus the signal, and not a file watcher, is what makes an update
  reach the consumer.
- `MarketplaceLayer` is one marketplace as the consumer sees it: `layer`, a
  `DotfolderStack.Layer` with the source `.marketplace`; `provenance`; and
  `isWatchable`, `true` for a folder on this computer and `false` for a
  cache-backed root. `MarketplaceProvenance` holds `id`, `url`, `sha` and
  `catalogVersion`, and `displayText` names the snapshot without the URL.
- `MarketplaceLayout` names the shape of a marketplace tree:
  `documentName`, the document that marks an entry folder, with no default;
  `excludedDirectoryNames`, with the default `.git` and `node_modules`; and
  `partialsDirectoryName`, with the default `_partials`.
- `MarketplaceSource` names one marketplace: `url`, `ref`, `sha`, `path`,
  `alias`, `select` and `autoUpdate`. It has no `grants` field: a
  marketplace layer always renders untrusted, and there is no
  per-marketplace permission. `SkillSelection` is `.all`, `.plugins(_:)` or
  `.skills(_:)`.
- `MarketplacePolicy` is what the host lets the store do: `snapshotLimits`,
  `allowedSources` and `blockedSources` over `SourcePattern` (`.exact`,
  `.owner(host:owner:)`, `.hostRegex`, `.pathPrefix`), `credentials`,
  `checkInterval`, `autoUpdate`, `checkOnly`, `applyUpdates`
  (`.immediately` or `.nextLaunch`) and `fetchTimeout`.
  `automaticUpdatesAllowed(environment:)` reads
  `SKILLS_MARKETPLACE_AUTOUPDATE`. `SnapshotLimits` holds `maxBytes` and
  `maxFiles`. `MarketplaceCredential` holds `username` and `token`, and its
  description, its debug description and its mirror show no secret.
- `MarketplaceListing` is one marketplace as a read-only list shows it:
  `id`, `key`, `url`, `currentSha`, `catalogVersion`, `lastChecked`,
  `isLocalFolder`, `holdsOneCommit` and `lastError`.
  `MarketplaceStore.listings(of:cacheDirectory:)` gives one for each source,
  in list order. It reads `state.json` of the cache, opens no connection and
  needs no store, thus it is the whole read behind a list command. A source
  whose URL is of no supported form gives a listing that carries the message
  of the parser and no URL, thus a list shows every source and no
  credential. `MarketplaceStore.cacheDirectoryVariable` and
  `MarketplaceStore.seedDirectoryVariable` name the two environment
  variables of the cache. The layout of the cache stays inside the product:
  no public type names a folder of it or a file in it.
- `MarketplaceConfig` is the `marketplaces.yaml` list of a stack:
  `load(from:includeProject:)` reads the user layer and the project layer,
  and `save(to:)` writes one file. A failure is a `MarketplaceConfigError`
  that names the file.
- `MarketplaceEvent` is `.checked`, `.updateAvailable`, `.updated` or
  `.failed`, each with the display id and the commits, and never a URL or
  a credential. `MarketplaceStatus` holds `id`, `current`, `latest`,
  `error` and `updateAvailable`. `MarketplaceDiagnostic` holds a
  `severity` of `.advisory`, `.warning` or `.error`, a `marketplaceID` and
  a `message`.
- `GitTransport` is the protocol of the fetch: `remoteHead` and `fetch`,
  each with a credential provider that is asked one time and only for the
  origin of the source. `LibGit2Transport` is the one implementation; it
  never starts the `git` binary. `GitTransportError` is `.unreachable`,
  `.refNotFound`, `.cancelled`, `.timedOut` or `.libgit2(code:message:)`.
- `MarketplaceFixtures` is a product for the tests of a consumer:
  `GitFixtureRepository` builds a bare repository with libgit2 only;
  `MarketplaceStoreFixture` builds a store over a temporary cache;
  `RecordingGitTransport`, `GatedGitTransport`, `ManualClock`,
  `MarketplaceEventLog` and `TestSignal` let a store test wait on no real
  time.

### Added: `ProcessRunner`, the family's process runner

`ProcessRunner.run(executable:arguments:workingDirectory:timeout:outputCap:registry:)`
runs one executable directly, with no shell, in its own process group. It
merges stdout and stderr into one bounded tail, kills the whole group with
`SIGKILL` at the timeout, and holds the pid in a `ProcessRegistry` from the
spawn to the reap. The `registry` parameter defaults to
`ProcessRegistry.global`, so the `atexit` sweep is the backstop for a run
that a normal exit of the host cuts short.

**Cause.** `FoundationModelsSkills` carried a runner of its own, with no
link to `ProcessRegistry`: a session that ended while a script ran left the
process group behind. The runner is not skill semantics. It belongs beside
the registry, so each consumer of the family gets the same limits and the
same backstop.

**What changed.**

- `ProcessRunner.OutputCap` names the two limits of the kept output: the
  count of complete lines, and the most bytes the run holds at one time.
  The read cuts at the byte limit while it runs, so a process that writes
  without end does not grow the memory of the caller.
- `ProcessRunner.Outcome` names what happened: `termination` is
  `.exited(code:)`, `.signaled(_:)`, or `.timedOut`; `lineCount` is the
  count of all the lines the process wrote; `output` is the kept tail; and
  `isTruncated` marks a cut. `duration` is the wall-clock time of the run.
- `ProcessRunner.Failure` is thrown when the spawn did not reach exec
  (`.spawnFailed(status:)`), or when the reap failed (`.waitFailed(errno:)`).

### Added: `DotfolderStack` is directory-shaped, and `DotfolderStacking` is its interface

This change breaks the source of a consumer that names the type
`DotfolderStack.Located`. That type is now the generic `Located<Item>` at the
top level of the module, and `enumerate(_:suffix:)` gives
`[String: Located<String>]`. A consumer that reads `url` and `layer` from an
`enumerate` result, and does not name the type, compiles with no change.
`nearest`, `content`, `locate` and `enumerate` keep their signatures and their
results.

**Cause.** The stack was file-shaped and flat. It could find one file, and it
could list the files of one subdirectory by suffix, but it could not give a
view of a directory tree. A layer is a directory tree, and a consumer that
holds a skill at `<root>/<id>/SKILL.md` with scripts and references beside it
needs one combined view of the trees of all the layers.

**What changed.**

- The stack is directory-shaped. It gives one combined view of the directory
  trees of all the layers. The unit of override is the file: for a path
  relative to a layer root, the copy in the highest layer that holds that path
  wins. A directory is never replaced; it holds the union of the names of all
  the layers. The view is computed at the time of the call. The stack holds no
  cache, thus it needs no file watcher; a consumer that caches a result keeps
  its own watcher.
- `DotfolderStack.tree(_:)` is new. It gives the recursive combined view of a
  subdirectory, or of the layer roots when the argument is `nil`. The key is
  the file path relative to the subdirectory, at every depth.
- `DotfolderStack.childDirectories(of:)` is new. It gives each immediate child
  directory name of the union, with the layers that hold it, lowest precedence
  first.
- `DotfolderStack.layerDirectories(_:)` is new. It gives the layers that hold
  a directory, lowest precedence first, and an empty array when no layer holds
  it.
- `DotfolderStacking` is a new protocol, generic in `Item`, what one lookup
  gives back. It has `layers`, `item(at:)`, `items(in:named:)`, `tree(_:)`,
  `childDirectories(of:)`, `layerDirectories(_:)`, `data(_:)`, `data(_:in:)`,
  `size(of:)` and `exists(_:)`. `DotfolderStack` conforms with
  `Item == String`.
- `Located<Item>` is new, and it replaces `DotfolderStack.Located`. It holds
  `url`, `layer` and `value`, the value the stack made from the winning file.
- `DotfolderStack.item(at:)` is new. It gives the winning copy of a path with
  its layer and its text. `items(in:named:)` gives, for each child directory
  of the union that holds a named file, that file; one call gives each
  `<id>/SKILL.md` of a skill directory.
- `DotfolderStack.data(_:)`, `data(_:in:)`, `size(of:)` and `exists(_:)` are
  new. They give the bytes, a byte range, the size, and the presence of the
  winning copy, thus a consumer never needs `FileManager`.
- Each lookup resolves the symbolic links of its candidate and refuses a path
  that leaves its layer root, in addition to the text check that refuses an
  empty path, an absolute path, and a `..` component. This rule came from the
  `PathConfinement` type of `FoundationModelsSkills`.
- `enumerate(_:suffix:)` is now the top level of `tree(_:)`, filtered by
  suffix. Its result does not change.
