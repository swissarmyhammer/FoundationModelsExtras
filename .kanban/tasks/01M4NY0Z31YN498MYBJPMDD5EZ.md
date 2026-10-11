---
assignees:
- claude-code
depends_on:
- 01M4NYF7Z3AVWM359N4KAGHNVN
position_column: todo
position_ordinal: 8a80
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
- [ ] Each embed call opens one `FoundationModelsExtras.embed` span with the six attributes, and one `FoundationModelsExtras.embed.tokenize` child span.
- [ ] Each sub-batch opens one `FoundationModelsExtras.embed.sub_batch` child span with `rows`, `longest_row`, `padded_tokens` and `pad_ratio`.
- [ ] Each call records one `FoundationModelsExtras.embed.duration`, adds its token count to `FoundationModelsExtras.embed.tokens`, and records `FoundationModelsExtras.embed.sub_batch.padded_tokens` for each sub-batch, all with `model.ref`.
- [ ] No span, log record or metric carries the text of an input.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchDivisionTests.swift`: test the pure helper with known rows: the token count, the longest row, the sub-batch count, the over-budget rows, the padded tokens and the pad ratio.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the embed texts (for example in `PooledEmbedderTests.swift`). The test also asserts that the capture saw at least one record, so that a test that sees nothing fails.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature