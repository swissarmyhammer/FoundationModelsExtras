---
assignees:
- claude-code
depends_on:
- 01M73FTQ8MB6JSDYYR9BYWJHBD
position_column: todo
position_ordinal: '8280'
title: 'LogitsTelemetry: one span and metrics for each logProbabilities call'
---
## What
Record telemetry for each `logProbabilities(of:after:)` call of `PooledLogitsModel` (`Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`). Put the trace in `PooledLogitsModel`, so that each backend (MLX and llama.cpp) gets it with no extra code.

Create `Sources/FoundationModelsExtras/Telemetry/LogitsTelemetry.swift`. Use the same pattern as `EmbedTelemetry` in `Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift`: the span goes through `TracedCall`, and the metrics are made at call time, so that they use the metrics factory of the current task.
- [ ] `enum LogitsTelemetry` with `static func traceLogProbabilities(of ref: ModelRef, candidates: [Int], prompts: [[Int]], body: …) async throws -> [[Double]]`.
- [ ] One span for each call, with the attributes `model.ref`, `logits.prompt_count`, `logits.candidate_count` and `logits.token_count` (the sum of the prompt lengths). On an error, the span records the error.
- [ ] Metrics: a call counter and a duration timer, with the `model.ref` dimension. Record the duration on the success path and on the error path.
- [ ] The span and the metrics contain no prompt text and no token IDs.
- [ ] `PooledLogitsModel.logProbabilities` calls `LogitsTelemetry.traceLogProbabilities`.

## Acceptance Criteria
- [ ] One `logProbabilities` call with 3 prompts of 4, 5 and 6 tokens and 2 candidates gives one span with `logits.prompt_count` 3, `logits.candidate_count` 2 and `logits.token_count` 15.
- [ ] The call counter increments by 1 and the timer records 1 value, also when the call throws.
- [ ] No attribute of the span holds prompt text or token IDs.

## Tests
- [ ] Create `Tests/FoundationModelsExtrasTests/Telemetry/LogitsTelemetryTests.swift`, with the same capture helpers as `Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift`. Add a `LogitsTelemetryExpectations` enum next to `EmbedTelemetryExpectations` in `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift` when this helps. Use the `FakeLogits` stub of the PooledLogitsModel tests. Test the success path, the error path and the absence of text and token IDs.
- [ ] Run `swift test --filter LogitsTelemetry`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision