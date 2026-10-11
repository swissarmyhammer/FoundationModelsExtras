---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4p9by170de24s6sgf5t91q9
  text: |-
    Research:
    - `withTracer` binds `InstrumentationSystem._taskLocalInstrument`. That task-local is `internal`, and `withTaskLocalInstrument` is `package`. Thus this repo cannot read the task-local directly. `InstrumentationSystem.instrument` is public and gives the task-local instrument, or else the bootstrapped instrument. `withTracer` accepts only a `Tracer`, thus `InstrumentationSystem.instrument as? any Tracer` gives the bound tracer exactly. When it gives the bootstrapped tracer, a bind of it in the job changes nothing. When the bootstrapped instrument is a multiplex (not a `Tracer`), the job binds nothing and sees the same global instrument.
    - `ServiceContext.withValue(_:isolation:operation:)` restores the trace context.
    - The job ticket (`QueueTicket.factory`) already keeps the metrics factory of the submitter, from `Job.init`, which runs on the task of the submitter in `submit` and in `enqueue`. The job reuses that factory for `withMetricsFactory`. It does not read the factory a second time.
    - The Job reads the context and the tracer in `Job.init`, which `submit(isolation:onQueued:_:)` and `enqueue(_:)` call on the task of the submitter. This is the same place that reads the factory into the ticket.
    - The `ModelCallMark` test passes before the change too: it is a guard that the restore stays selective.
  timestamp: 2026-10-11T20:09:48.327849+00:00
- actor: claude-code
  id: 01m4p9qnj44zcqr41mba44erhw
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsExtras/ModelPool/GenerationQueue.swift (new private `SubmitterTelemetry`; `Job` keeps it; `run()` restores the trace context, the tracer and the ticket factory around `runBody()`; doc comments updated), Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift (4 new tests in `GenerationQueueWorkerTaskTests`). RED: 3 of the new tests failed for the expected reason (no job span, missing metric); the ModelCallMark guard passed before and after. GREEN: `swift test --filter GenerationQueueWorkerTaskTests` 6/6 passed. Full `swift test`: 952 tests in 89 suites passed, 11 known issues (the existing `withKnownIssue` tests of TelemetryCapture), no warning except the mlx-swift `missing creator for mutated node` line.
    - next: /review
  timestamp: 2026-10-11T20:16:12.868552+00:00
- actor: claude-code
  id: 01m4pb67cdxhfwfzt698dxby6x
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~2..HEAD` (1d6ff21, 06ad0c0). 0 findings, 0 confirmed, 0 refuted. 7 validator-file pairs attempted, 0 failed. 4 source files reviewed. 4 `.kanban/` files not reviewed, because `.reviewignore` excludes them. The task had no earlier findings section.
    - next: none. The task moved to `done`.
  timestamp: 2026-10-11T20:41:38.445537+00:00
- actor: claude-code
  id: 01m4pb68kxrfhd1cshb1jq959j
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files
    - test: green — swift test, 953 passed (test step also fixed the hostname lookup in TemplateEngine)
    - commit: 1d6ff21, 06ad0c0
    - review: clean — 0 findings
  timestamp: 2026-10-11T20:41:39.709300+00:00
depends_on:
- 01M4NXR89BEEM8Q023M7S472C8
position_column: done
position_ordinal: ed80
title: 'GenerationQueue: carry the trace context of the submitter into the job, so spans inside a model call keep their parent'
---
## What

`Job.run()` (`Sources/FoundationModelsExtras/ModelPool/GenerationQueue.swift:225`) runs each job in `Task.detached`. A detached task gets no task-local value. Thus `ServiceContext.current`, the tracer that `withTracer` binds, and the metrics factory that `withMetricsFactory` binds are lost in the job:
- A tool span that opens inside a model call (a tool that the model calls during `respond`) starts a new root trace. Its "enter" log record has no parent trace id.
- `TelemetryCapture` cannot see a span or a metric inside a queue job.

The detach is necessary: it keeps `ModelCallMark` and other task-local values of the submitter out of the job (see the doc comment at `:223`). Do not remove the detach.

Change:
- In `submit(isolation:onQueued:_:)` (`:58`) and `enqueue(_:)` (`:90`), read `ServiceContext.current` and the current metrics factory, and keep them in the `Job`.
- In the detached task of `run()`, run `body` inside `ServiceContext.withValue(context)`. Restore the tracer binding in the same way, if `withTracer` is a task-local of `Tracing` (read `Sources/FoundationModelsExtras/Telemetry/TracedCall.swift` and `Tests/TelemetryTestSupport/TelemetryCapture.swift` to see how the tracer is bound). Also restore the metrics factory with `withMetricsFactory(captured)`.
- Restore only the trace context, the tracer and the metrics factory. Do not restore `ModelCallMark` or other task-local values.
- Update the doc comment at `:223`.

Limit: a log record that a job body writes is not visible to `TelemetryCapture`. `TelemetryLogRouting.currentContext` is a test-only task-local, and production code cannot restore it. Production log records are not affected, because production logging does not use that task-local.

## Acceptance Criteria

- [x] A span that opens inside a job body has the span of the submitter as its parent.
- [x] `TelemetryCapture.run(forbidding:)` sees a span and a metric that a job body writes.
- [x] `ModelCallMark.current` is still `nil` inside a job body (the detach still isolates the job).

## Tests

- [x] Add tests in the existing `Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift`: open a span with `W3CInMemoryTracer` (from `TelemetryTestSupport`), submit a job that opens a child span, and check the parent id and the trace id.
- [x] Add a test that a metric that a job body records reaches the `TestMetrics` of the `withMetricsFactory` of the submitter.
- [x] Add a test that `ModelCallMark.current` is `nil` in the job.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug