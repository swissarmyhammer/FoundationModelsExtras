---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4pcz92g9z2rjm9k4be3s411
  text: |-
    Research done.
    - `RunPlane.settle(_:with:)` is the one exit from `runs`. The sweep and `settleByItself` both call it. A late body of a swept run finds no run, thus it records nothing.
    - Elicitations leave the list at three places: `respond` (`.delivered` path), `complete`, and `sweep`. A URL accept stays in the list.
    - `TracedCall.run` throws only the error of its body. The run body does not throw, but the type needs a `catch`.
    - `start` gets no session tracer. `BackgroundToolRunner` owns `site.tracer`, and the body `Task` inherits the task-local tracer and service context of the caller. Thus the run span uses `InstrumentationSystem.tracer` at call time (tracer `nil`), and it is a child of the tool span. I do not change the signature of `start`, because `BackgroundToolRunner.swift` is outside this task.
    - Reuse: `QueueTelemetry`, `ExtrasTelemetry.telemetryOutcome(of:)`, `ToolCallSpan.outcomeOfTerminalWithNoOutcome` (a terminal with no outcome is `lost`), `QueueMetricDimensions` in the tests.
    - Plan: the elicitation task gets no `started` call. Its wait timer is the user think time, and it records no run time. Outcome: `accept` and `decline` give `succeeded` (the user answered), `cancel` and the sweep give `cancelled`.
  timestamp: 2026-10-11T21:12:47.952353+00:00
- actor: claude-code
  id: 01m4pe1myy7ew04fjzbt528e9v
  text: |-
    Implementation done (TDD: RED run showed each new test fail for the missing telemetry; GREEN run passed).
    - `RunPlane.start` enqueues and starts a `run_plane` ticket after the duplicate-token guard. `settle(_:with:)` completes it with `ExtrasTelemetry.telemetryOutcome(of:)`; a terminal with no outcome gives `lost` through `ToolCallSpan.outcomeOfTerminalWithNoOutcome`.
    - Elicitations: `elicitation` ticket at `awaitAnswer`, never started (the wait timer is the think time, no run timer). One `finish(_:with:)` helper completes it at `respond` (delivered path), `complete`, and `sweep`. Accept and decline give `succeeded`, cancel and the sweep give `cancelled`.
    - Run body runs in `TracedCall.run(ExtrasTelemetry.SpanName.run)` with `tool.name`, `run.kind` and `run.completion_token` as span attributes and log metadata. The `catch` of that call is reachable only by type (the body does not throw): it asserts, logs `error.type`, and settles the run as `lost`.
    - New vocabulary in `ExtrasTelemetry.swift`: `SpanName.run`, `AttributeKey.backgroundRunKind`, `AttributeKey.completionToken`, and the same two `LogMetadataKey` names.
    - Blast radius: two existing tests counted every metric of a background call and broke, because the run plane now adds its `run_plane` metrics. `ToolCallSpanTests.aBackgroundStartGivesItsMetrics` and `ExtrasContentSafetyTests.aBackgroundCallCarriesNoContent` now call `runPlane.joinRunBodies()` inside the capture and expect the tool span plus the run span, and the tool-call metrics plus the queue metrics (shared lists in `MountFixtures`). The tool span and the run span can end in each order, thus those checks sort the names.
    - Not done here, recorded as ^j0tmteq: the run span uses `InstrumentationSystem.tracer`, not `site.tracer`, because `start` gets no tracer and `BackgroundToolRunner.swift` is outside this task.
  timestamp: 2026-10-11T21:31:34.238753+00:00
- actor: claude-code
  id: 01m4pe1qxmq1q7tfh2mxsb1r35
  text: |-
    ### implement — changed
    - evidence: `swift test` — 973 tests in 90 suites passed, 11 known issues (from before), no compiler warning (only the mlx-swift_Cmlx.bundle "missing creator" line from the dependency build). 6 files — Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift, Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/ExtrasContentSafetyTests.swift
    - next: /review
  timestamp: 2026-10-11T21:31:37.268258+00:00
- actor: claude-code
  id: 01m4perybfsza62r7act8w07y3
  text: |-
    ### review — findings
    - evidence: `review sha acb87b9~1..acb87b9` — 3 findings (3 confirmed, 2 refuted). Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:634, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:714, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:848
    - next: /implement the open items of the `## Review Findings (2026-10-11 16:38)` section
  timestamp: 2026-10-11T21:44:17.519877+00:00
- actor: claude-code
  id: 01m4pes00j4ap2yervbpg8z34x
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files
    - test: green — swift test, 973 passed
    - commit: acb87b9
    - review: findings — Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:634, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:714, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:848
  timestamp: 2026-10-11T21:44:19.218828+00:00
- actor: claude-code
  id: 01m4peymqcqtc0fskvwqv0739n
  text: |-
    Picked up the 3 open review findings. Research:
    - The 3 suites with the same queue-metric checks are `RunPlaneActorTests` (`expectOneTask`, `depth`), `MailboxTests` (`expectLetters`, `depth`) and `QueueTelemetryTests` (`expectOneTask`, `depthDimensions`, inline `expectMeter` depth reads). Plan: one `QueueMetricExpectations` enum in `ModelPoolTestSupport.swift` after `QueueMetricDimensions`, with `expectCompletedJobs(in:queue:outcome:ran:count:)` and `depth(in:queue:)`. It checks the count, the wait and run timer counts, that each duration is not negative, and that no other outcome has a count. Each suite uses one outcome for each factory, thus the other-outcome check holds in each suite. The explicit "no succeeded count" check in `MailboxTests.aCancelledRunningLetterRecordsItsRunTimeOneTime` is then a repeated check, and I remove it.
    - The completed `OperationEvent` with `FakeRun.tool`, `FakeRun.op` and the token occurs 5 times in `RunPlaneActorTests` and 1 time in `FakeRun.start`. Plan: one `FakeRun.terminalEvent(token:outcome:detail:)` in `RunPlaneTestSupport.swift`, called from all 6 places.
    - The run span name and the enter message are hand-written strings. Plan: `ExtrasTelemetry.SpanName.run` and `ExtrasTelemetry.EnterRecord.message(forSpanNamed:)`.
  timestamp: 2026-10-11T21:47:24.268393+00:00
- actor: claude-code
  id: 01m4pfah02gbm5pnmrcjpdxk6c
  text: |-
    The 3 review findings are done. Each is now `- [x]`.
    - Finding 1: `QueueMetricExpectations` in `ModelPoolTestSupport.swift`, after `QueueMetricDimensions`. It has `expectCompletedJobs(in:queue:outcome:ran:count:)` (a `String` outcome and a `QueueOutcome` outcome) and `depth(in:queue:)`. It checks the task count, the wait and run timer counts, that no duration is negative, and that no other outcome has a count. `RunPlaneActorTests` calls it directly; its `expectOneTask`, its `depth` and its `oneTask` constant are gone. `QueueTelemetryTests` calls it directly; its `expectOneTask`, the inline `expectMeter` depth reads and the `oneCount`/`oneDuration`/`noTime` constants are gone, and `depthDimensions` is now `queueDimensions(model:)` on `QueueMetricDimensions.queue(named:model:)`. `MailboxTests` keeps `expectLetters` and `depth` only as one-line forwarders that name the mailbox queue; the checks are in the shared helper. Its `oneTask` constant and its explicit "no succeeded count" check are gone, because the shared helper checks each other outcome.
    - Finding 2: `FakeRun.terminalEvent(token:outcome:detail:)` in `RunPlaneTestSupport.swift`. `FakeRun.start` and all 5 places in `RunPlaneActorTests` that built a completed `OperationEvent` now call it.
    - Finding 3: `runEnterMessage` is `ExtrasTelemetry.EnterRecord.message(forSpanNamed: runSpanName)`. `runSpanName` keeps the literal span name on purpose: no other test pins `SpanName.run` to `FoundationModelsExtras.run`.
    - Discovery: the `files` tool `edit file` with `replace_all: true` replaced only 1 occurrence. Use one edit for each block.
  timestamp: 2026-10-11T21:53:53.666203+00:00
- actor: claude-code
  id: 01m4pfakc2j7g0270gqgrkea96
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` has no error and no warning. `swift test`: 973 tests in 90 suites passed with 11 known issues (these were there before), and 381 tests in 28 suites passed. 5 files: Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestSupport.swift, Tests/FoundationModelsExtrasTests/Telemetry/QueueTelemetryTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift
    - next: /review
  timestamp: 2026-10-11T21:53:56.098633+00:00
- actor: claude-code
  id: 01m4pfqy7ktrrffgxrrz3x3wrq
  text: |-
    ### review — findings
    - evidence: `review sha c0e46ae~1..c0e46ae` — 2 findings (2 confirmed, 1 refuted). Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestSupport.swift:135, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:347
    - next: /implement the open items of the `## Review Findings (2026-10-11 16:56)` section
  timestamp: 2026-10-11T22:01:13.203865+00:00
- actor: claude-code
  id: 01m4pfqz8s84y1w0qwvvtzmyhw
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 5 files
    - test: green — swift test, 973 passed
    - commit: c0e46ae
    - review: findings — Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestSupport.swift:135, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:347
  timestamp: 2026-10-11T22:01:14.265614+00:00
- actor: claude-code
  id: 01m4pghkr1nckvx7z7e5a961n0
  text: |-
    The 2 review findings of 16:56 are done. Each is now `- [x]`.
    - Finding 1 (terminal event): one shared helper `OperationEvent.terminal(tool:op:token:outcome:detail:)` in `RunPlaneTestSupport.swift` builds each completed event of the test target. The tool, the op and the token have empty defaults, for a context that stamps them. `FakeRun.terminalEvent` is now a one-line forwarder that names the fake tool and op. `RunPlaneTestingSPIPublicSurfaceTests` uses `FakeRun.tool`, `FakeRun.op` and `FakeRun.terminalEvent`; its own `tool`, `op` and `terminalEvent` are deleted. The whole-target search found 7 more hand-built completed events; each now calls `OperationEvent.terminal`: `ToolContextTests` (4), `MountFixtures.OwnTerminalTool`, `MountingFixtures.AmbientNonStringOutputTool`, `ToolCallSpanTests.aTerminalEventWithNoOutcomeRecordsOneCall`.
    - Finding 2 (queue metrics): `GenerationQueueWorkerTests` calls `QueueMetricExpectations` (String outcomes, `QueueMetricDimensions.queue(named:)`). Its `expectOneJob`, `oneTask`, `oneDuration` and the metric-name strings in `QueueMetric` are deleted; `QueueMetric` keeps only the queue dimensions and the outcome strings. New readers in `QueueMetricExpectations`: `taskCounts`, `waitTimes`, `runTimes` (String outcome). The whole-target search found more copies; each now uses the shared helpers: `ModelPoolTests` (2 tests, `oneTask` deleted), `GenerationQueueEnqueueTests` (2 tests, `oneTask` deleted). What stays: the metric-name pins in `QueueTelemetryTests` and the label list in `MountFixtures`, which are not metric checks.
    - Discovery: `expectCompletedJobs` also checks that no other outcome has a count. `aCancelledWaitingJobRecordsNoRunTime` has a holder job that succeeds beside the cancelled job, so that check failed. Fix: a new `expectCompletedJobs(in:queue:_ expected: [CompletedJobs])` takes one group for each outcome and excludes all of them from the other-outcome check. The single-outcome function forwards to it, so each other caller keeps the same checks. The test now also checks the holder (succeeded, ran).
  timestamp: 2026-10-11T22:15:14.433352+00:00
- actor: claude-code
  id: 01m4pghqn9m4gchhhpcfq3kgf0
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` has no error and no warning (only the mlx-swift_Cmlx.bundle "missing creator" line of the dependency build). `swift test`: 973 tests in 90 suites passed with 11 known issues (these were there before), and 381 tests in 28 suites passed. 11 files: Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueEnqueueTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestSupport.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestingSPIPublicSurfaceTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift, Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/MountingFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift, .kanban task card
    - next: /review
  timestamp: 2026-10-11T22:15:18.441151+00:00
depends_on:
- 01M4NXXETD1P6X4V8RMA0XRDQ5
position_column: doing
position_ordinal: '80'
title: 'Queue metrics: RunPlane records the open runs and the timing of each run, and a span covers each run body'
---
## What

`RunPlane` (`Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift:10`) holds each background run, but it records no metric and the run body has no span. A background run that hangs after its settle period shows nothing in the telemetry.

Approach:
- Give the run plane one `QueueTelemetry` with the queue name `run_plane` (from task `w9g6hm8`). A run is one queue task.
  - `start(tool:op:kind:completionToken:canceler:body:)` (`:145`): `enqueued`, then at once `started`, after the duplicate-token guard (`:153-155`). A duplicate token records nothing.
  - `settle(_:with:)` (`:491`): `completed`, with the outcome from the terminal event, mapped with the shared bounded mapping of task `w9g6hm8`: `succeeded`, `failed`, `timed_out`, `stopped`, `cancelled`, `lost` or `other`. Do not collapse an outcome to `failed`. `settle` is the one place where a run leaves `runs`, thus the sweep and the settle by the body both pass through it, and each run records one completion only.
  - The depth is the count of open runs (`runs`).
- Give the run plane a second `QueueTelemetry` with the queue name `elicitation`, for `RunPlane.elicitations` (the actor list of pending elicitations in `RunPlaneActor.swift`). One pending elicitation is one queue task.
  - `enqueued` when an elicitation is appended to the list.
  - `completed` when it leaves the list: at answer, at accept, or at sweep. Each elicitation records one completion only.
  - The depth is the count of pending elicitations.
  - The wait of an elicitation is user think time. Keep it out of the tool latency: do not add it to the tool-call duration or to the `run_plane` timers.
- Open a `TracedCall` span `FoundationModelsExtras.run` around the run body in the `Task` at `:156-160` (around `await body()` at `:157`). Attributes: `tool.name`, the run kind (`RunKind`) and the completion token. The span gives an "enter" log record, so a hung body has an enter record and an open span after its settle period.
- Do not record the completion token or the op as a metric dimension, because the cardinality has no limit. The token can be a span attribute.
- Put each new name in `ExtrasTelemetry.swift`. Make the metric objects at call time. Never record tool arguments, tool output, the progress detail or the elicitation content.
- Keep the contract of `joinRunBodies()` (`:399`): after `sweep()`, it returns only when each run body ended.

## Acceptance Criteria
- [x] Each started run adds 1 to the depth meter, and its settle takes 1 away. The depth is 0 after each run settles.
- [x] Each run records one `queue.tasks` count with `queue.name=run_plane` and the bounded `queue.outcome` of task `w9g6hm8`, also when the sweep settles the run. A `lost` run records `lost`, not `failed`.
- [x] Each pending elicitation records one `queue.tasks` count with `queue.name=elicitation` at answer, accept or sweep, and the `elicitation` depth goes back to 0.
- [x] The wait of an elicitation is not part of the tool-call duration or of the `run_plane` timers.
- [x] Each run body has one `FoundationModelsExtras.run` span and one "enter" log record, with `tool.name` and the run kind.
- [x] No metric dimension carries the completion token or the op.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift`: with `MetricsTestKit` `TestMetrics`, test the depth, the timers and the outcome for a run that succeeds, a run that fails, a run that times out, a run that is lost, a run that the sweep settles, and a duplicate token.
- [x] Tests for the `elicitation` queue: an elicitation that gets an answer, one that is accepted, and one that the sweep removes. Each records one count, and the depth goes back to 0.
- [x] A span test with `W3CInMemoryTracer`: a body that does not return has an open span and an enter record; a body that returns ends its span.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the progress detail and the terminal detail.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature

## Review Findings (2026-10-11 16:38)

> Scope: `review sha acb87b9~1..acb87b9` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:634` `reuse/reuse` — The `expectOneTask` helper repeats the one-completed-queue-task assertions that already exist in other test suites. Three copies of the same queue-metric check can drift apart. Move the shared queue-metric assertions into `ModelPoolTestSupport.swift` next to `QueueMetricDimensions`, parameterized by the `ran` flag, and call that helper from all three suites. Do the same for the `depth` reader.
- [x] `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:714` `reuse/reuse` — `aDuplicateTokenRecordsNothing` builds the same completed `OperationEvent` inline that `settleRun` already builds. The same event shape is now written in two places in one file. Give `settleRun` (or a small sibling helper) an entry point that takes the token and the start closure, or extract a helper that builds the completed event from a token and an outcome. Call it from both places.
- [x] `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift:848` `reuse/reuse` — The test hard-codes the "enter" log message text, which rebuilds the format that the production helper already produces. If the message format changes, this constant goes stale while the production helper still passes. Replace the literal with `ExtrasTelemetry.EnterRecord.message(forSpanNamed: runSpanName)`, as `ToolCallSpanTests.swift` does, and remove the hand-written string.

## Review Findings (2026-10-11 16:56)

> Scope: `review sha c0e46ae~1..c0e46ae` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestSupport.swift:135` `reuse/reuse` — The new static func FakeRun.terminalEvent builds the same OperationEvent as an existing helper. A second copy must now be kept in step with the first. Call the existing terminalEvent helper, or move one shared helper into RunPlaneTestSupport.swift and make RunPlaneTestingSPIPublicSurfaceTests use it. Then delete the duplicate.
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:347` `reuse/reuse` — The new shared QueueMetricExpectations.expectCompletedJobs repeats the checks of an existing queue-metric helper in GenerationQueueWorkerTests. That suite keeps its own copy, so the checks are still in two places, which is the reason for this change. Migrate GenerationQueueWorkerTests.expectOneJob and its QueueMetric helper to call QueueMetricExpectations.expectCompletedJobs, then delete the local copies.
