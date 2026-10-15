---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50qrnfmv9b1nx1ww2abkqhk
  text: |-
    Picked up. The coordinating session accepted the design: a new requirement `OperationEventSink.post(elicitationCompleted:)` with an empty default (no new case in `OperationEventKind`, `ElicitationAnswerDelivery` or `ElicitationCompletionDelivery`), an internal `completing` closure on `RunPlane.awaitAnswer`, an internal `RunPlane.complete(elicitationId:runToken:)`, and a public `ToolContext.complete(elicitationId:)`.

    Research:
    - Only two types in Sources wrap a sink: `RunEventFunnel` (ToolRun.swift) and `MountedRunUpstreamSink` (ToolContext.swift). Both must forward the new call. `MountedRunUpstreamSink` forwards through the private `sink` of the mounting context, the same path as the elicitation event.
    - `ToolContext.elicit` posts the elicitation event to its own `sink` (the run funnel for a mounted run, the host sink for a host context). The completion must go to that same sink.
    - The existing test helpers `AwaitedCondition.wait` and `MountFixtures.poll` poll. The new tests do not use them. They use an AsyncStream sink; the stream also ends when the sink is released, so a test whose event never comes fails and does not hang.
  timestamp: 2026-10-15T21:33:49.940352+00:00
- actor: claude-code
  id: 01m50r6jn71k959hz01tqz550b
  text: |-
    Implementation landed (not committed).

    Public API changes (all additive):
    - `OperationEventSink.post(elicitationCompleted elicitationId: ULID) async`, a new requirement with an empty default in the protocol extension.
    - `ToolContext.complete(elicitationId: ULID) async -> ElicitationCompletionDelivery` (`@discardableResult`).
    No new case in `OperationEventKind`, `ElicitationAnswerDelivery` or `ElicitationCompletionDelivery`. The signature of `RunPlane.complete(elicitationId:)` does not change.

    Internal changes:
    - `RunPlane.awaitAnswer(to:runToken:posting:completing:)`: the pending elicitation keeps `completing`. A private `completeAccepted(elicitationId:linkedTo:)` is the one place that ends an accepted URL flow and starts `Task { await completing() }`. The public `complete(elicitationId:)` and the new internal `complete(elicitationId:runToken:)` both call it. Respond, the run cancel, the sweep, the headless cancel and the duplicate-id cancel do not start it.
    - `ToolContext.elicit` passes `completing` with the same sink as `posting`.
    - `RunEventFunnel` forwards the completion upstream through its serial delivery chain, also after the terminal event. `MountedRunUpstreamSink` forwards it through the sink of the mounting context (a new fileprivate `ToolContext.postElicitationCompleted(_:)`).

    Tests: `ElicitationCompletionEventTests` (8 tests, `@testable`) and `ElicitationCompletionPublicSurfaceTests` (1 test, plain import). Each wait reads an AsyncStream. The signalling sink finishes its stream in `deinit`, and in most tests only the asking tasks hold the sink, so a test whose completion never comes fails and does not hang. This is how the RED run ended with failures and no hang.

    RED: `swift test --filter ElicitationCompletion` with the API surface and no behavior: 9 tests, 9 failed (10 issues).
    GREEN: same filter: 9 tests, 9 passed.
    Full `swift test` (one run): exit 0; Swift Testing 1153 tests in 112 suites passed, plus 131, 40, 44, 26 and 410 tests in the other test products, 0 failures. The only warning is the build-system note "missing creator for mutated node" for mlx-swift_Cmlx.bundle, which was also there before this change. No compiler warnings.
  timestamp: 2026-10-15T21:41:25.799996+00:00
- actor: claude-code
  id: 01m50r6nex0abc0sx813qb7j8e
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/OperationEvents/OperationEventSink.swift, Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift, Sources/FoundationModelsExtras/Hosting/ToolContext.swift, Sources/FoundationModelsExtras/Hosting/ToolRun.swift, README.md, Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionEventTests.swift (new), Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionPublicSurfaceTests.swift (new). RED 9/9 failed, GREEN 9/9 passed, full swift test exit 0 (1153 + 131 + 40 + 44 + 26 + 410 tests passed, 0 failures), no new compiler warnings.
    - next: /review
  timestamp: 2026-10-15T21:41:28.669119+00:00
- actor: claude-code
  id: 01m50rjpsvb9wj0rgsna3yrkrf
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit e0d9e2f). 3 findings, 3 confirmed, 0 refuted. Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionEventTests.swift:160, Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionPublicSurfaceTests.swift:10, Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionPublicSurfaceTests.swift:49
    - next: Correct the three reuse/reuse findings. Use one shared test helper for a host ToolContext and one shared signalling sink. Then run the review again.
  timestamp: 2026-10-15T21:48:03.259248+00:00
- actor: claude-code
  id: 01m50rwkpp3mnpr8wp59xpte8n
  text: |-
    The three reuse/reuse findings are corrected (not committed).

    - One shared host context builder: `MountFixtures.hostContext(on:sink:completionToken:)`, with `MountFixtures.hostTool` and `MountFixtures.hostOp`. `ElicitationCompletionEventTests` and `ElicitationCompletionPublicSurfaceTests` call it. The private `hostContext` and the inline `ToolContext(...)` call are removed.
    - `RunPlaneHeadlessQuestionTests.makeContext` now calls the shared builder. Its private constants `hostTool` and `hostOp` are removed, because no test reads the tool name or the op. The test checks do not change. No other old test changed.
    - One sink type: `ElicitationSignal`, `SignallingSink` and `SignalReader` moved into the new file `Tests/FoundationModelsExtrasTests/Hosting/ElicitationSignalling.swift`. That file has a plain import, so it uses only the public API, and the plain-import file can use the sink.
    - The actor `QuestionStreamingSink` is removed. The public-surface file keeps a sink that implements `post(event:)` only (`EventOnlySink`), so `post(elicitationCompleted:)` still comes from the public default. That sink has no stream and no deinit: it gives each event to a `SignallingSink`, and the test reads the `.asked` signal with `SignalReader`. The calls `ToolContext.complete(elicitationId:)` and the default `post(elicitationCompleted:)` stay in the file with the plain import.

    Note: the public-surface file no longer calls the `ToolContext` initializer directly. `ToolHostingPublicSurfaceTests` still calls it over a plain import, so the public initializer stays covered.

    Filtered run `swift test --filter "ElicitationCompletion|RunPlaneHeadlessQuestionTests"`: 14 tests in 3 suites passed.
    Full `swift test` (one run): exit 0; 1153 tests in 112 suites passed, plus 131, 40, 44, 26 and 410 tests in the other test products, 0 failures. The only warning is the old build-system note "missing creator for mutated node" for mlx-swift_Cmlx.bundle. No compiler warnings.
  timestamp: 2026-10-15T21:53:27.766788+00:00
- actor: claude-code
  id: 01m50rwpdrtmw1bw407hk50a1k
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsExtrasTests/Hosting/ElicitationSignalling.swift (new), Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionEventTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionPublicSurfaceTests.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneHeadlessQuestionTests.swift. Filtered run 14/14 passed. Full swift test exit 0 (1153 + 131 + 40 + 44 + 26 + 410 passed, 0 failures). No new warnings. 3 of 3 findings checked.
    - next: /review
  timestamp: 2026-10-15T21:53:30.552668+00:00
depends_on:
- 01M50MVD045658RXD65ASVTTYB
position_column: doing
position_ordinal: '80'
title: A host tool ends its own accepted URL flow, and the run plane posts an event when a URL flow completes
---
Source: elicitation-plan.md, task 8 (phase 3: the async question path).

Today `elicitation/complete` goes to the client at consent, because nothing on the tool side ends a URL flow.

- [x] Send a design to the coordinating session, and get acceptance before code.
- [x] A host tool can end its own accepted URL flow, for example with `ToolContext.complete(elicitationId:)`.
- [x] When `RunPlane.complete(elicitationId:)` completes an accepted URL flow, from any source, the run plane posts a sink event (for example an `OperationEvent` of a new kind `elicitationCompleted` with the id), in the same way as the event of a new question today. Router can then report it.
- [x] Additive public API only. Tell the coordinating session each public API change before the push.
- [x] Fixed-order tests that fail on the old code. No clock, sleep, poll, retry or time limit.
- [x] One full test run.

Start this task after the task that validates answers against the requested schema. FoundationModelsMultitool and FoundationModelsRouter follow after this task.

#elicitation-phase-3

## Review Findings (2026-10-15 16:42)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionEventTests.swift:160` `reuse/reuse` — The new private helper hostContext(on:sink:) builds a ToolContext in the same way as the existing makeContext helpers in other test suites. This adds one more copy of the same constructor call with the same placeholder values. Move one shared ToolContext test builder into a common fixture file and let hostContext, makeContext and makeHarness call it, or parameterize the existing makeContext with the run plane and the sink so this suite can use it.
- [x] `Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionPublicSurfaceTests.swift:10` `reuse/reuse` — The new actor QuestionStreamingSink repeats the shape of the existing SignallingSink: an AsyncStream made with makeStream, a stored continuation, a deinit that finishes the stream, and a post(event:) that yields the question id. It is a near-match that was not extended. The file uses a plain import, but both files are in the same test module, so SignallingSink can be used here. A parameter or a second stream type would avoid the copy. Reuse SignallingSink from ElicitationCompletionEventTests.swift and read its `.asked` signals with SignalReader, or move SignallingSink into a shared test support file and use it from both test files. Do not keep a second actor with the same stream and deinit code.
- [x] `Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionPublicSurfaceTests.swift:49` `reuse/reuse` — The test builds a ToolContext inline with the same argument list as the new private helper hostContext. The helper is not reused, so the constructor call is copied in a second place. If the ToolContext initializer changes, both copies must change. Use one shared test helper for a host ToolContext. Move hostContext into a shared test fixture, such as MountFixtures, and call it from both files.
