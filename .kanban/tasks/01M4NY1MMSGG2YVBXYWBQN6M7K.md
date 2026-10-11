---
assignees:
- claude-code
depends_on:
- 01M4NYFBJJHE656GQR76E1AESD
position_column: todo
position_ordinal: 8b80
title: 'Generate telemetry: a span for each model call with time to first token, tokens per second and cold or warm'
---
## What

A model call has no span and no metric. The operator cannot see the time to the first token, the speed of the model, or whether a call had to load the model first.

The integration test with the real LLM is in task `ac35ek3`.

Files and points:
- `Sources/FoundationModelsExtras/ModelPool/PooledModel.swift`: `PooledModel.respond(to:streamingInto:)` (`:91`). It loads the model with `resident.loaded()` (`:95`), then submits the call to the model queue (`loaded.hold.queue.submit`, `:96-98`). `PooledModelExecutor.respond(to:model:streamingInto:)` (`:144`) calls it.
- `Sources/FoundationModelsExtras/ModelPool/PooledSession.swift`: `respond(to:)` (`:64`) and `respond(to:generating:)` (`:80`, the guided call) submit the session call to `hold.queue`.

Approach (each name in `ExtrasTelemetry.swift`, metric objects made at call time):
- Span `FoundationModelsExtras.generate` through `TracedCall`, so that a hung call has an "enter" record. Attributes: `model.ref`, `generate.guided` (`true` for `respond(to:generating:)` at `:80`, else `false`), and `generate.cold` (`true` when the call included a load, else `false`). Do not use the `cache.result` key here: `cache.result` keeps only the values `hit`, `late_hit` and `load` of task `556w4rs`.
- Open the span before the load and the queue wait, so that it is the parent of the load span (task `8r1175p`, when it exists) and each tool span that opens in the call. The queue wait is a metric (`FoundationModelsExtras.queue.wait`, task `7s472c8`), not a span. Task `7752wag` carries the `ServiceContext` into the detached queue job; this task depends on it.
- Wrap the `LanguageModelExecutorGenerationChannel` to see the first event and the end:
  - Timer `FoundationModelsExtras.generate.time_to_first_token` (from the span start to the first event) and Timer `FoundationModelsExtras.generate.duration`, both with `model.ref`.
  - When the channel gives token counts: Counter `FoundationModelsExtras.generate.output_tokens` and Recorder `FoundationModelsExtras.generate.tokens_per_second`, both with `model.ref`. When the channel gives no counts, record neither.
- Never record the prompt, the instructions, the transcript or the output text.

## Acceptance Criteria
- [ ] Each model call opens one `FoundationModelsExtras.generate` span with `model.ref`, `generate.guided` and `generate.cold`, and writes one "enter" log record.
- [ ] The first call after a load records `generate.cold=true`. A later call records `generate.cold=false`.
- [ ] Each call records `FoundationModelsExtras.generate.time_to_first_token` and `FoundationModelsExtras.generate.duration`. When the channel gives token counts, the call records `FoundationModelsExtras.generate.output_tokens` and `FoundationModelsExtras.generate.tokens_per_second`.
- [ ] The load span and each tool span of the call have the generate span as their parent.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`: with `StubLanguageModel.swift` and a fake loader, `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test the span, the attributes, cold and warm, the timers, and a stub that gives token counts and one that gives none.
- [ ] A parent test: a tool span that opens inside the call has the generate span as its parent.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the prompt and the output text. The test also asserts that the capture saw at least one record.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature