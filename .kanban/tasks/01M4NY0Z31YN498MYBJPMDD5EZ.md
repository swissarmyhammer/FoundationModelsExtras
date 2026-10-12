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
- actor: claude-code
  id: 01m4r58bw8z42my6mh9svs4g5f
  text: |-
    ### review — findings
    - evidence: review sha c6e557e~1..c6e557e — 2 findings (2 confirmed, 1 refuted). Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift:72, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:918
    - next: /implement to correct the two open findings in the 2026-10-12 08:33 Review Findings section
  timestamp: 2026-10-12T13:36:25.992232+00:00
- actor: claude-code
  id: 01m4r58d9przwsyd0gsecye4jj
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 files
    - test: green — swift test, 1016 passed; IntegrationTests embed, 9 passed
    - commit: c6e557e
    - review: findings — Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift:72, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:918
  timestamp: 2026-10-12T13:36:27.446045+00:00
- actor: claude-code
  id: 01m4r5dmjpg3h70g8qyqxfr1wm
  text: |-
    Research for the 08:33 findings:
    - In `traceEmbed`, the tokenize and model closures do not throw now, thus only a traced call can throw. To test a failed call, the `vectors` closure becomes `throws` (a model run can fail). The MLX closure stays as it is.
    - Plan for the duration: a do/catch around the body of the embed span, as in `ModelLoadTelemetry.traceLoad`. Each path records the timer with `model.outcome` (`ModelOperationOutcome`).
    - Token counter: it is recorded when the tokenize step ends, before the model runs. Thus a failed call also counts its tokens. It keeps `model.ref` only (the card names that dimension), and a comment states why.
    - Padded-tokens recorder: now recorded after the model run of the sub-batch, thus a sub-batch that throws records nothing. The padded tokens are known before the run, thus the plan records them before the run, on both paths.
    - Test support: three places build the `model.ref` dimension (PoolMetricExpectations, ModelLoadTelemetryExpectations, EmbedTelemetryExpectations), and the `model.outcome` dimension is built in two places. Plan: one shared `ModelMetricDimensions` enum in ModelPoolTestSupport.swift; each enum calls it, and the copies go.
  timestamp: 2026-10-12T13:39:18.742727+00:00
- actor: claude-code
  id: 01m4r5pndnrmjaatgyjsn88d30
  text: |-
    Findings of 08:33 corrected (TDD: RED seen for the success-duration test, the failed-duration test and the failed-padding test; then GREEN).
    - EmbedTelemetry: the `vectors` closure now `throws`. The body of the embed span is a do/catch (as in `ModelLoadTelemetry.traceLoad`). Each path records `embed.duration` with `model.outcome` (`succeeded` or `failed`). The span steps moved to `embedInSpan` to keep the function short.
    - Token counter: already recorded on both paths (it is recorded when the tokenize step ends, before the model runs). It keeps `model.ref` only; a doc comment states why.
    - Padded-tokens recorder: moved before the model run, thus a sub-batch whose run throws also records its padded tokens; a doc comment states this.
    - ExtrasTelemetry docs of `embedDuration`, `modelOutcome` and `ModelOperationOutcome` now name the embed call.
    - Test support: new `ModelMetricDimensions` enum (`model(_ ref:)`, `model(_ key:)`, `model(_:outcome:)`). The three private copies (PoolMetricExpectations, ModelLoadTelemetryExpectations, EmbedTelemetryExpectations) are gone; the inline `model.ref` tuple of `acquireCounts` and the inline outcome tuple of the model-load timer also use it. `TracedFakeEmbedding` has `modelRunFails`; `FakeModelRunError` is new.
    - New tests in EmbedTelemetryTests: a failed call records one `failed` duration and no `succeeded` duration; a failed call adds its token count and records the padded tokens of the failed sub-batch.
  timestamp: 2026-10-12T13:44:14.517142+00:00
- actor: claude-code
  id: 01m4r5pqsht8c829g87jts7acv
  text: |-
    ### implement — changed
    - evidence: `swift test --filter 'Embed|PooledEmbedder'` 36 tests passed; `swift test` all suites pass (1018 + 381 + 131 + 44 + 40 + 26; the 11 known issues are the existing withKnownIssue of TelemetryCaptureTests); no compiler warning except the mlx-swift "missing creator" line. Files: Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift. Both 08:33 findings are `- [x]`.
    - next: /review
  timestamp: 2026-10-12T13:44:16.945736+00:00
- actor: claude-code
  id: 01m4r5zh7h99bw6gv0f1meztyr
  text: |-
    ### review — findings
    - evidence: review sha 04f61b3~1..04f61b3 — 1 finding (1 confirmed, 2 refuted). Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift:59
    - next: /implement to correct the open finding in the 2026-10-12 08:46 Review Findings section
  timestamp: 2026-10-12T13:49:05.137156+00:00
- actor: claude-code
  id: 01m4r5znwmq7f7c0225s5sfsgk
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 4 files
    - test: green — swift test, 1018 passed; IntegrationTests PooledEmbedder, 7 passed
    - commit: 04f61b3
    - review: findings — Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift:59
  timestamp: 2026-10-12T13:49:09.908651+00:00
- actor: claude-code
  id: 01m4r65c71z50chr7qe8mpkhpc
  text: |-
    Finding `EmbedTelemetryTests.swift:59` `reuse/reuse` is done. `captureOneCall(of:)` is now the only capture wrapper in EmbedTelemetryTests.swift. It takes the embedding (default `embedding`) and gives `(context, outcome: Result<[[Float]], any Error>)`. `captureOneFailedCall()` now calls `captureOneCall(of: failingEmbedding)` and expects `FakeModelRunError` from `outcome.get()`. It has no second `TelemetryCapture.run`. The vector-order test reads the vectors with `try outcome.get()`. PooledEmbedderTests.swift has only one `TelemetryCapture.run` and no near-copy helper, so it did not change. Note: the rules dump for .swift is 754K characters, so it was not read whole.

    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift. `swift test --filter 'Embed|PooledEmbedder'`: 36 tests in 5 suites passed. `swift test`: 1018 tests in 91 suites passed, with 11 known issues (the withKnownIssue tests in TelemetryCaptureTests). The only warning is the SwiftPM build-system note "missing creator for mutated node" for the mlx-swift_Cmlx.bundle. It does not come from source code.
    - next: /review
  timestamp: 2026-10-12T13:52:16.609096+00:00
- actor: claude-code
  id: 01m4r6ayhmz5rfnryg722kjf06
  text: |-
    ### review — clean
    - evidence: review sha f7d1ad0~1..f7d1ad0 — 0 findings (0 confirmed, 0 refuted). 1 file reviewed. All prior Review Findings items are `- [x]`.
    - next: none. The task is in done.
  timestamp: 2026-10-12T13:55:19.220350+00:00
- actor: claude-code
  id: 01m4r6azjt91jg9m9egcz1e61k
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — 1 file
    - test: green — swift test, 1018 passed
    - commit: f7d1ad0
    - review: clean — 0 findings
  timestamp: 2026-10-12T13:55:20.282692+00:00
depends_on:
- 01M4NYF7Z3AVWM359N4KAGHNVN
position_column: done
position_ordinal: f880
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

## Review Findings (2026-10-12 08:33)

> Scope: `review sha c6e557e~1..c6e557e` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsExtras/Telemetry/EmbedTelemetry.swift:72` `completeness/public-output-contract` — The embed duration timer is recorded only after `vectorsOfEachSubBatch` returns. When the model run or a traced sub-batch throws, no duration is recorded, so failed embed calls drop their duration side-effect without any outcome dimension. The sibling duration timers (`modelLoadDuration`, `toolDuration`) record the outcome on failure too, so this path is silently incomplete. Record the embed duration on both the success and the error path, for example with `defer` around the start time, or with a `do/catch` that records the timer before it rethrows. Add an outcome dimension if the sibling timers carry one, and add a test that a throwing embed call still records one duration.
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:918` `reuse/reuse` — The new `EmbedTelemetryExpectations.modelDimensions(of ref:)` is a verbatim copy of `modelDimensions(of ref:)` in the same file, which is already used by the pool expectations. The two copies sit in different enums, so each one is private to its own enum and they can drift apart. Make the existing helper at line 659 internal, or move it to a shared test-support location. Have `EmbedTelemetryExpectations` call it instead of keeping a second copy. Delete the copy at line 918.

## Review Findings (2026-10-12 08:46)

> Scope: `review sha 04f61b3~1..04f61b3` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsExtrasTests/Telemetry/EmbedTelemetryTests.swift:59` `reuse/reuse` — The new `captureOneFailedCall()` is a near-copy of the existing `captureOneCall()`. It repeats the `TelemetryCapture.run(forbidding: texts)` wrapper and differs only in which embedding runs and whether the error is expected. The existing helper was not parameterized to cover the failing case. Give `captureOneCall` a parameter for the embedding, or make one helper that takes a body closure. Then `captureOneFailedCall` becomes a call that passes `failingEmbedding` and the expected error, with no second capture wrapper.
