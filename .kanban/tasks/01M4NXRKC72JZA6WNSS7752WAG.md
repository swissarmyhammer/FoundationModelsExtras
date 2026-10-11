---
assignees:
- claude-code
depends_on:
- 01M4NXR89BEEM8Q023M7S472C8
position_column: todo
position_ordinal: '8280'
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

- [ ] A span that opens inside a job body has the span of the submitter as its parent.
- [ ] `TelemetryCapture.run(forbidding:)` sees a span and a metric that a job body writes.
- [ ] `ModelCallMark.current` is still `nil` inside a job body (the detach still isolates the job).

## Tests

- [ ] Add tests in the existing `Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift`: open a span with `W3CInMemoryTracer` (from `TelemetryTestSupport`), submit a job that opens a child span, and check the parent id and the trace id.
- [ ] Add a test that a metric that a job body records reaches the `TestMetrics` of the `withMetricsFactory` of the submitter.
- [ ] Add a test that `ModelCallMark.current` is `nil` in the job.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug