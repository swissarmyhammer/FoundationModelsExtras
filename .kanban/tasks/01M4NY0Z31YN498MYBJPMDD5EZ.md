---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4r4b4x1mqxq4sf2hcg7trps
  text: |-
    Research done. Findings:
    - `EmbedderModelContainer.perform` takes an `async throws` closure, and `SerialAccessContainer.read` runs it in the same task (AsyncMutex). Thus TracedCall can run inside the closure, and the task-local tracer, metrics factory and service context of the queue job stay in effect.
    - `EmbeddingBatchDivision` does not keep its token budget. The plan stores `tokenBudget` in the division, so that the pure helper (`EmbeddingBatchStatistics`) reads the budget from the division and cannot get a different value.
    - Plan: put the steps of one embed call (tokenize span, division, sub-batch spans, metrics) in one generic function `EmbedTelemetry.traceEmbed(of:texts:tokenize:vectors:)` in `Telemetry/EmbedTelemetry.swift`. `MLXEmbedding.embed` calls it with the MLX tokenizer and the MLX model run. A unit test calls it with a fake tokenizer, so the spans and metrics have unit tests with no model. `MLXEmbedding` keeps the `ModelRef` of its key from `load`.
    - The content-safety test in `PooledEmbedderTests` uses a test embedding that calls `EmbedTelemetry.traceEmbed`, through the pool and the queue.
    - The shared span and metric checks go in `ModelPoolTestSupport.swift` (`EmbedTelemetryExpectations`).
    - Constraint: a sub-batch span uses the async `TracedCall.run`, thus the sub-batch loop cannot use `map` (a `map` closure cannot `await`).
  timestamp: 2026-10-12T13:20:28.577255+00:00
- actor: claude-code
  id: 01m4r4sge4bt0b4dq90nmgcd95
  text: |-
    Implementation landed (TDD: RED seen for the statistics tests, then for the span, metric and content-safety tests; then GREEN).
    - `EmbeddingBatchDivision` now keeps `tokenBudget`. The pure helper `EmbeddingBatchStatistics(of:)` (new file in ModelPool) gives the six call counts and, for each sub-batch, rows, longest row, padded tokens and pad ratio (0 when the sub-batch has no tokens).
    - `EmbedTelemetry.traceEmbed(of:texts:tokenBudget:tokenize:vectors:)` (new file in Telemetry) runs one call: embed span (TracedCall) -> tokenize child span -> one sub-batch child span for each sub-batch. It records the token counter after the tokenize step, the padded-tokens recorder in each sub-batch span, and the duration timer as the last step of the embed span. All with `model.ref` only.
    - `MLXEmbedding` keeps the `ModelRef` of its key from `load(ref:...)`, and `embed(texts:)` calls `traceEmbed` inside `container.perform`. The guard for empty texts is gone, so an empty call also has its spans (zero counts) and returns [].
    - New names are only in `ExtrasTelemetry.swift`. Sub-batch attribute keys: `embed.sub_batch.rows`, `embed.sub_batch.longest_row`, `embed.sub_batch.padded_tokens`, `embed.sub_batch.pad_ratio`.
    - Tests: `EmbedTelemetryTests` (new), statistics tests in `EmbeddingBatchDivisionTests`, content-safety test in `PooledEmbedderTests`. The shared fake (`TracedFakeEmbedding`) and the shared checks (`EmbedTelemetryExpectations`) are in `ModelPoolTestSupport.swift`.
    - Discovery: test texts must not be hex-like. A short text like "ab" can match a random hex trace id in the metadata of an "enter" record, which makes a content-safety test flaky. The test texts hold `q` and `z`.
    - Note for ^6e1aesd: the shared checks live in the unit test target; the IntegrationTests package cannot see them.
  timestamp: 2026-10-12T13:28:19.140962+00:00
- actor: claude-code
  id: 01m4r4sm5ba2z5tvbpna3z7w4t
  text: |-
    ### implement — changed
    - evidence: `swift test` all suites pass (1016 + 381 + 131 + 44 + 40 + 26 tests; the 11 known issues are the existing withKnownIssue of TelemetryCaptureTests); no compiler warnings except the mlx-swift "missing creator" line. Files: Sources/FoundationModelsExtras/ModelPool/EmbeddingBatchDivision.swift, Sources/FoundationModelsExtras/ModelPool/EmbeddingBatchStatistics.swift (new), Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift (new), Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchDivisionTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift (new)
    - next: /review
  timestamp: 2026-10-12T13:28:22.955598+00:00
depends_on:
- 01M4NYF7Z3AVWM359N4KAGHNVN
position_column: doing
position_ordinal: '80'
title: 'Embed telemetry: a span for each embed call and each sub-batch, with token and padding counts'
---
## What

An embed call has no span and no metric. The sub-batch division (`EmbeddingBatchDivision`) can make a call fast or slow, but the padding and the token counts are not visible.

The integration test with the real embedding model is in task `6e1aesd`.

Files and points:
- `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`: `MLXEmbedding.embed(texts:)` (`:253`) tokenizes each text (`context.tokenizer.encode`, `:257`), makes an `EmbeddingBatchDivision` (`:256`), and calls `vectors(of:padToken:in:)` (`:271`) for each sub-batch, which pads with `EmbeddingBatchPadding` (`:272`) and runs the model.
- `Sources/FoundationModelsExtras/ModelPool/EmbeddingBatchDivision.swift`: `subBatches` (`:35`), `SubBatch.rows` (`:30`), `defaultTokenBudget` (`:22`).
- `MLXEmbedding` does not keep its `ModelRef` now. Give it the ref of its key at load (`MLXEmbedding.load`, `:232`), or record the metrics where the key is known.

Approach (each name in `ExtrasTelemetry.swift`, metric objects made at call time):
- Span `FoundationModelsExtras.embed` with `model.ref`, `embed.text_count`, `embed.token_count`, `embed.max_tokens`, `embed.sub_batch_count` and `embed.over_budget_rows` (rows longer than the budget, each in a sub-batch by itself).
- Child span `FoundationModelsExtras.embed.tokenize` around the tokenize step, so the tokenize time is separate from the model time.
- Child span `FoundationModelsExtras.embed.sub_batch` for each sub-batch, with `rows`, `longest_row`, `padded_tokens` (rows x longest row) and `pad_ratio` (pad tokens / padded tokens).
- Timer `FoundationModelsExtras.embed.duration` and Counter `FoundationModelsExtras.embed.tokens` with `model.ref`. Recorder `FoundationModelsExtras.embed.sub_batch.padded_tokens` with `model.ref`.
- Compute the attribute values in one pure helper from an `EmbeddingBatchDivision` and the budget, so that a unit test needs no model.
- Never record a text, a token id or a vector.

## Acceptance Criteria
- [x] Each embed call opens one `FoundationModelsExtras.embed` span with the six attributes, and one `FoundationModelsExtras.embed.tokenize` child span.
- [x] Each sub-batch opens one `FoundationModelsExtras.embed.sub_batch` child span with `rows`, `longest_row`, `padded_tokens` and `pad_ratio`.
- [x] Each call records one `FoundationModelsExtras.embed.duration`, adds its token count to `FoundationModelsExtras.embed.tokens`, and records `FoundationModelsExtras.embed.sub_batch.padded_tokens` for each sub-batch, all with `model.ref`.
- [x] No span, log record or metric carries the text of an input.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchDivisionTests.swift`: test the pure helper with known rows: the token count, the longest row, the sub-batch count, the over-budget rows, the padded tokens and the pad ratio.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the embed texts (for example in `PooledEmbedderTests.swift`). The test also asserts that the capture saw at least one record, so that a test that sees nothing fails.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature