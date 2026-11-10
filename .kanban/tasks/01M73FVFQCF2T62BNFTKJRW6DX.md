---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73jvm7prfwer0tbavmqne9e
  text: |-
    Research done.
    - EmbedTelemetry.traceEmbed is the pattern: TracedCall.run with a model.ref attribute and log metadata, metrics made at call time, the duration timer records on the success path and on the error path with the model.outcome dimension (ModelOperationOutcome).
    - All telemetry names live in ExtrasTelemetry (SpanName, AttributeKey, MetricName). The new names go there.
    - docs/REFERENCE.md and README.md list no span names and no metric names, thus no doc change.
    - FakeLogits (ModelPoolTestSupport.swift) never throws. The error-path test needs a fake that throws: add a `failsLogProbabilities` flag with a default of false, so the memberwise init of the current callers stays the same.
    - TelemetryCapture.run(forbidding:) checks span attributes, log metadata and metric dimensions, not metric values. Token IDs are numbers: the test uses 9-digit IDs, so a hex trace ID or span ID cannot hold one by chance.
    - Decision: the duration timer also has the model.outcome dimension, the same as the embed and generate timers. The call counter has the model.ref dimension only.
  timestamp: 2026-11-10T20:37:11.030119+00:00
- actor: claude-code
  id: 01m73k4058z4m9qdar5snfy051
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift (new), Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift (span name `FoundationModelsExtras.logits`, attributes `logits.prompt_count`, `logits.candidate_count`, `logits.token_count`, metrics `FoundationModelsExtras.logits.calls` and `FoundationModelsExtras.logits.duration`, docs of the outcome and the dimensions), Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift (logProbabilities goes through LogitsTelemetry), Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift (new, 10 tests), Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift (FakeLogits.failsLogProbabilities, LogitsTelemetryExpectations). RED: 7 of 10 failed for the missing span and metrics. GREEN: `swift test --filter "LogitsTelemetry|PooledLogitsModel"` gave 25 tests in 2 suites passed. `swift build --build-tests` gave no warnings.
    - notes: the span holds the model load when the call loads the model. The duration timer also has the model.outcome dimension, the same as the embed timer. No doc lists telemetry names, thus no README or REFERENCE change. No other package calls PooledLogitsModel.
    - next: /review
  timestamp: 2026-11-10T20:41:45.384377+00:00
depends_on:
- 01M73FTQ8MB6JSDYYR9BYWJHBD
position_column: doing
position_ordinal: '80'
title: 'LogitsTelemetry: one span and metrics for each logProbabilities call'
---
## What
Record telemetry for each `logProbabilities(of:after:)` call of `PooledLogitsModel` (`Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`). Put the trace in `PooledLogitsModel`, so that each backend (MLX and llama.cpp) gets it with no extra code.

Create `Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift`. Use the same pattern as `EmbedTelemetry` in `Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift`: the span goes through `TracedCall`, and the metrics are made at call time, so that they use the metrics factory of the current task.
- [x] `enum LogitsTelemetry` with `static func traceLogProbabilities(of ref: ModelRef, candidates: [Int], prompts: [[Int]], body: …) async throws -> [[Double]]`.
- [x] One span for each call, with the attributes `model.ref`, `logits.prompt_count`, `logits.candidate_count` and `logits.token_count` (the sum of the prompt lengths). On an error, the span records the error.
- [x] Metrics: a call counter and a duration timer, with the `model.ref` dimension. Record the duration on the success path and on the error path.
- [x] The span and the metrics contain no prompt text and no token IDs.
- [x] `PooledLogitsModel.logProbabilities` calls `LogitsTelemetry.traceLogProbabilities`.

## Acceptance Criteria
- [x] One `logProbabilities` call with 3 prompts of 4, 5 and 6 tokens and 2 candidates gives one span with `logits.prompt_count` 3, `logits.candidate_count` 2 and `logits.token_count` 15.
- [x] The call counter increments by 1 and the timer records 1 value, also when the call throws.
- [x] No attribute of the span holds prompt text or token IDs.

## Tests
- [x] Create `Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift`, with the same capture helpers as `Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift`. Add a `LogitsTelemetryExpectations` enum next to `EmbedTelemetryExpectations` in `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift` when this helps. Use the `FakeLogits` stub of the PooledLogitsModel tests. Test the success path, the error path and the absence of text and token IDs.
- [x] Run `swift test --filter LogitsTelemetry`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision