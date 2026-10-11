---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4p0xwzebnm7ms7nj4yavp77
  text: |-
    Research done.
    - swift-metrics in .build has `withMetricsFactory` (task local) and `MetricsSystem.factory` reads the task-local factory first. `Counter`, `Meter` and `Metrics.Timer` each have `init(label:dimensions:factory:)`. Thus the ticket keeps `MetricsSystem.factory` from `enqueued()`, and `started` / `completed` make each metric with that factory.
    - `TestMetrics` gives back the same handler for the same label and dimensions. Thus a new `Meter` object for each enqueue and each completion moves one shared depth value. `TestMeter.values` keeps each value in order.
    - `TelemetryCapture` (Tests/TelemetryTestSupport) uses `W3CInMemoryTracer` and `TestMetrics`, and binds them with `withTracer` / `withMetricsFactory`. A detached task gets no capture.
    - Now `tool.outcome` uses `OperationOutcome.rawValue` in `ExtrasTelemetry.toolCallDimensions` and in `ToolCallSpan.record(outcome:on:)`. The `.other` case gives the text of the tool.
    - Plan: put `QueueName`, `QueueOutcome`, the new metric names, a new `DimensionKey` enum and the mapping `telemetryOutcome(of:)` in ExtrasTelemetry.swift. Put `QueueTelemetry` and `QueueTicket` in the new QueueTelemetry.swift.
  timestamp: 2026-10-11T17:42:19.886760+00:00
- actor: claude-code
  id: 01m4p1cqqg0733y53jphfgska9
  text: |-
    Implementation landed (TDD: the new tests did not compile before the feature, then they passed).
    - ExtrasTelemetry.swift: the four queue metric names, a new `DimensionKey` enum (`queue.name`, `model.ref`, `queue.outcome`), the top-level internal enums `QueueName` and `QueueOutcome` (both `String, Sendable, CaseIterable`), and `ExtrasTelemetry.telemetryOutcome(of:)`, an exhaustive switch with no `default`. `toolCallDimensions` now uses this mapping. The type doc comment and the doc of `AttributeKey.outcome` are updated.
    - ToolCallSpan.record(outcome:on:): the span attribute now uses `telemetryOutcome(of:)`. `OperationOutcome.rawValue` did not change.
    - New QueueTelemetry.swift: `QueueTelemetry` and `QueueTicket`. The ticket keeps `MetricsSystem.factory` from `enqueued()`. Each metric is made with `init(label:dimensions:factory:)` and that factory.
    - Tests: the new QueueTelemetryTests (8 tests, with the detached test and the cancelled-before-start test), 4 new mapping tests in ExtrasTelemetryTests, and 2 new tests in ToolCallSpanTests (`tool.outcome=other` on the span and on the metrics, and a content-safety test that forbids the `.other` text and asserts 1 span and 2 metric records).
    - Notes: the `diagnostics` tool shows SourceKit errors for the new symbols. They come from a stale index, because `swift build` and `swift test` pass. The full `swift test` log has one SwiftPM build-system line "warning: missing creator for mutated node" for `.build/out/Products/Debug/mlx-swift_Cmlx.bundle`. It is not a compiler warning, and it does not come from a source file of this change.
  timestamp: 2026-10-11T17:50:26.032721+00:00
- actor: claude-code
  id: 01m4p1ctxzyxwf677q9hx0ga69
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/QueueTelemetry.swift (new), Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift, Tests/FoundationModelsExtrasTests/Telemetry/QueueTelemetryTests.swift (new), Tests/FoundationModelsExtrasTests/Telemetry/ExtrasTelemetryTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift. `swift test --filter 'FoundationModelsExtrasTests.(QueueTelemetry|ExtrasTelemetry|ToolCallSpan)'`: 31 tests in 3 suites pass. `swift test`: exit 0, 933 Swift Testing tests in 89 suites pass (11 known issues come from the existing withKnownIssue tests of TelemetryCaptureTests), and the XCTest runs pass.
    - next: /review
  timestamp: 2026-10-11T17:50:29.311195+00:00
depends_on: []
position_column: doing
position_ordinal: '80'
title: 'Telemetry: add the queue vocabulary and a shared QueueTelemetry recorder (depth, wait time, run time)'
---
## What

The code has no metric for a queue. Each queue of the package must record the same simple metrics: the queue depth, and the timing of each queue task when it completes. Make one shared recorder, so that each queue uses the same names and the same rules.

Files:
- `Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift`: add the names.
  - `MetricName.queueDepth = "FoundationModelsExtras.queue.depth"`: a `Meter`. The value is the count of tasks that are not finished (waiting + running).
  - `MetricName.queueWait = "FoundationModelsExtras.queue.wait"`: a `Timer`. The time from enqueue to start.
  - `MetricName.queueRun = "FoundationModelsExtras.queue.run"`: a `Timer`. The time from start to end.
  - `MetricName.queueTasks = "FoundationModelsExtras.queue.tasks"`: a `Counter`. One count for each task that completes.
  - Dimension keys: `queue.name` (a value of `QueueName`), `model.ref` (`ModelRef.stringValue`, only when the queue belongs to one model), `queue.outcome` (a value of `QueueOutcome`).
  - Update the doc comment of `ExtrasTelemetry`: a dimension now can also carry the queue name and the model ref.
- The queue name type is an internal `enum QueueName: String`. Its raw values are `model`, `admission`, `generation`, `run_plane`, `elicitation`, `tool_events` and `mailbox`. No other queue name is possible.
- The outcome type is an internal `enum QueueOutcome: String`. It carries the bounded telemetry value of a tool outcome. Its raw values are `succeeded`, `failed`, `timed_out`, `stopped`, `cancelled`, `lost` and `other`.
- Put one shared bounded mapping from `OperationOutcome` (`Sources/FoundationModelsExtras/OperationEvents/OperationOutcome.swift`) to that value in `ExtrasTelemetry`:
  - `.succeeded` → `succeeded`, `.failed` → `failed`, `.timedOut` → `timed_out`, `.stopped` → `stopped`, `.cancelled` → `cancelled`, `.lost` → `lost`, `.other(_)` → `other`.
  - Never map `.lost` to `failed`. The doc comment of `OperationOutcome` (`:11-23`) says that "we do not know if this ran" is not the claim "this ran and failed". Also keep `.stopped` and `.cancelled` separate.
  - Use this mapping for every telemetry use of a tool outcome: the `tool.outcome` metric dimension (`ExtrasTelemetry.toolCallDimensions`, `ExtrasTelemetry.swift:199-203`) and the span attribute (`Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift:104`). Now these use `OperationOutcome.rawValue`, whose `.other` branch (`OperationOutcome.swift:68-70`) gives the text of the tool, so the cardinality has no limit and the text can leak content.
  - Do not change `rawValue`, because it is the wire format.
  - This mapping was part (a) of task `vsvb1hx`.
- New file `Sources/FoundationModelsExtras/Telemetry/QueueTelemetry.swift`: an internal `Sendable` struct `QueueTelemetry`.
  - `init(name: QueueName, model: ModelRef? = nil)`.
  - `enqueued() -> QueueTicket`: increments the depth meter, and keeps the enqueue instant (`ContinuousClock.now`). The `QueueTicket` also keeps `MetricsSystem.factory`, the factory that is bound when `enqueued()` runs.
  - `started(_ ticket: inout QueueTicket)`: keeps the start instant.
  - `completed(_ ticket: QueueTicket, outcome: QueueOutcome)`: decrements the depth, and records `queue.wait` and `queue.run` together at completion, with the outcome as a dimension. A task that is cancelled before it starts records its wait time, no run time, and `cancelled`.
  - `started` and `completed` make each metric object at call time with the factory that the ticket keeps, not with the factory of the current task. Thus a completion that runs in a `Task.detached` still reaches the factory of the submitter, and `withMetricsFactory` in tests sees it.
- Record ids, names and counts only. Never record the content of a task.

Do not connect a queue in this task. Other tasks connect each queue.

## Acceptance Criteria

- [x] `ExtrasTelemetry` holds every new name. No other file has a telemetry string literal.
- [x] Each new metric name starts with `FoundationModelsExtras.`.
- [x] `QueueName` and `QueueOutcome` are internal enums with only the raw values above.
- [x] `QueueTelemetry` records the depth up at enqueue and down at completion. It records `queue.wait`, `queue.run` and `queue.tasks` at completion, with `queue.name`, `queue.outcome` and (when set) `model.ref`.
- [x] `QueueTicket` keeps the factory of `enqueued()`, and `started` / `completed` use it. A completion from a `Task.detached` reaches the factory of the submitter.
- [x] A task cancelled before start records a wait time, no run time, and the outcome `cancelled`.
- [x] The depth goes back to 0 after each task completes.
- [x] The shared mapping gives one fixed value for each `OperationOutcome` case. `.other("anything")` gives `other`, and `.lost` gives `lost`, not `failed`.
- [x] The `tool.outcome` metric dimension and the `tool.outcome` span attribute both use the shared mapping. A tool outcome `.other("anything")` gives `tool.outcome=other` on both. The wire `rawValue` does not change.

## Tests

- [x] New `Tests/FoundationModelsExtrasTests/Telemetry/QueueTelemetryTests.swift`: use `MetricsTestKit` `TestMetrics` through `withMetricsFactory`. Test the depth values, the timer values (wait ≥ 0, run ≥ 0), the dimensions, and the cancelled-before-start path.
- [x] A test that calls `enqueued()` inside `withMetricsFactory`, then calls `started` and `completed` from a `Task.detached`, and checks that `TestMetrics` of that `withMetricsFactory` has the wait time, the run time and the count.
- [x] `Tests/FoundationModelsExtrasTests/Telemetry/ExtrasTelemetryTests.swift`: the telemetry value of each `OperationOutcome` case; `.other` gives `other`; `.lost` gives `lost`.
- [x] `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift`: with `W3CInMemoryTracer` and `TestMetrics`, a tool outcome `.other("anything")` gives `tool.outcome=other` on the metric dimension and on the span attribute.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the `.other` text. The test also asserts that the capture saw at least one record.
- [x] `swift test --filter 'FoundationModelsExtrasTests.QueueTelemetry'` passes, and `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature