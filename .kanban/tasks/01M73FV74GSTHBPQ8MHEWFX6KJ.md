---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73hbkr8zknpchye67v9e09g
  text: |-
    Research:
    - `ModelContainer.perform(_:)` gives a `ModelContext` (model, tokenizer). `LanguageModel.nextTokenLogits(_:cache:state:)` gives logits `[B, L or 1, V]`. A fresh `newCache(parameters: nil)` per batch gives no cache from an earlier call. MLX is lazy, thus the vocabulary size (`dim(-1)`) is known before eval, and IDs can be checked before any GPU work.
    - The bridge tokenizer (`#adaptHuggingFaceTokenizer`) has `encode(text:addSpecialTokens:)` and `applyChatTemplate(messages:tools:additionalContext:)` that gives token IDs only (generation prompt on). No public API renders the template to text, thus the text is `decode(tokenIds:skipSpecialTokens: false)` of those IDs. `missingChatTemplate` maps to `nil`.
    - `ModelConfiguration` has no context length. `maximumPromptTokens` is synchronous, thus it reads `max_position_embeddings` (or `text_config.max_position_embeddings`) from `config.json` of the model folder: the `.directory` URL, or the Hub snapshot found from the cache folder of `weightsLocation`.
    - Qwen3-0.6B-4bit: `vocab_size` 151936 (logits width), `max_position_embeddings` 40960. The model is already in the default HF cache.
    - Rule conflict to note: the `test-partitioning` validator forbids an environment-variable gate, but this card (and the user) require the `EXTRAS_MLX_INTEGRATION` gate and forbid a new target. The card wins here; review must decide.
  timestamp: 2026-11-10T20:10:57.672921+00:00
- actor: claude-code
  id: 01m73hy4ebf6z375nj8hgy8yd9
  text: |-
    BLOCKER: the batching approach on this card cannot meet "batched results equal one-by-one results within 1e-4" with MLX.

    What was measured with Qwen3-0.6B-4bit (the probes were temporary; they are removed):
    - `MLXLogitsRealModel` with the flag: 7 of 8 tests pass. The mixed-length batch test fails. The length-5 batch matches exactly. The length-8 batch differs by 3.2e-5 and 2.0e-3.
    - A batch of B copies of ONE prompt against that prompt alone (largest difference of 4 candidates): L=2 B=16 0.24; L=4 B=4 0.003; L=7 B=2 0.010; L=8 B=4 0.39; L=8 B=16 0.60; L=16 B=2 0.29; L=33 B=16 0.16. Thus the cause is not padding and not the code: the same prompt gives different values when the batch is larger.
    - Cause: MLX selects the quantized matmul kernel by the row count M = B x L and by the GPU (`get_qmv_batch_limit` in mlx/backend/metal/quantized.cpp: qmv when M is below the limit, else qmm or split-K qmm). The kernels round the bf16 activations differently, and 28 layers make the difference larger. The public API of mlx-swift-lm has no control of this selection.
    - A fixed row count gives exact equality: in a forward pass of 16 rows, row 0 had the same values (difference 0.0 at L=2, 5, 8, 16, 33) when the other 15 rows were copies of it or a different prompt of the same length. Thus each row is independent of the other rows when M is the same.

    A person must select one of these:
    1. Always run each prompt alone (no batching). This gives exact equality. It removes the batching requirement.
    2. Fill each forward pass to a fixed count of 16 rows with copies of a real prompt of the batch (no pad tokens, no position change), for batched calls and for one-prompt calls. This gave exact equality in the probe. A one-prompt call then costs 16 forward rows.
    3. Change the acceptance tolerance. Not useful: the measured differences are up to 0.6.

    The rest of the card is done: `MLXLogits.swift` (conformance, `MLXLogitsError`, config.json prompt limit), `LogitsBatchDivision.swift` (same-length batches of up to 16, as the card says), `IndexedBatches.swift` (the input-order step that `EmbeddingBatchDivision` now shares), unit tests `LogitsBatchDivisionTests` and `MLXLogitsTests`, and `MLXLogitsRealModelTests`. A change for option 1 or 2 is local to `logProbabilities` / `LogitsBatchDivision`.
  timestamp: 2026-11-10T20:21:04.587818+00:00
- actor: claude-code
  id: 01m73hy7qvfctg1mhhxv6k4xtk
  text: |-
    ### implement — stuck
    - evidence: 7 files — Sources/FoundationModelsExtras/ModelPool/MLXLogits.swift, LogitsBatchDivision.swift, IndexedBatches.swift, EmbeddingBatchDivision.swift (adopts IndexedBatches); Tests/FoundationModelsExtrasTests/ModelPool/MLXLogitsTests.swift, LogitsBatchDivisionTests.swift, MLXLogitsRealModelTests.swift. `swift test`: all suites pass, 0 failures, no new warnings, "MLX logits real model" skipped. `EXTRAS_MLX_INTEGRATION=1 swift test --filter MLXLogitsRealModel`: 7 of 8 pass; "a batch of mixed-length prompts gives the values of one call for each prompt" fails (largest difference 2.0e-3 > 1e-4).
    - next: a person selects option 1 or 2 of the blocker comment (or another approach); then the batching item, the batch criterion and the flag run can be completed.
  timestamp: 2026-11-10T20:21:07.963004+00:00
- actor: claude-code
  id: 01m73hz64hgxrzrssj0fbktyac
  text: |-
    ### Decision: run each prompt alone
    - The requester (foundationmodelsdecision-6f) said: "Batch prompts up to 16, but results must equal the one-by-one results (pad correctly or run one by one)." The measurements show that MLX selects the quantized matmul kernel by row count, so a batch with a different row count does not give the same values. Thus use the permitted option: run one prompt for each forward pass, all inside one `ModelContainer.perform`.
    - Option 2 (fill each pass to 16 rows with copies) is not selected. It depends on the kernel selection of MLX, which can change in a later version, and a call with one prompt costs 16 rows.
    - Change the batching subtask to: "Run one prompt for each forward pass, in one `perform` call. A call with several prompts gives exactly the same values as one call for each prompt."
    - Remove the code that only the batch method needed (`LogitsBatchDivision`, and `IndexedBatches` if no other code needs it; then return `EmbeddingBatchDivision` to its earlier form).
    - The batch test asserts exact equality (difference 0) between a multi-prompt call and one-prompt calls.
  timestamp: 2026-11-10T20:21:39.089811+00:00
- actor: claude-code
  id: 01m73j5738wb8ch4wn5atq133m
  text: |-
    Implemented the decision "run each prompt alone":
    - `logProbabilities` now does one forward pass of shape [1, L] for each prompt, all inside one `loadContainer().perform`. `MLXForwardPass` now takes one prompt and gives one row.
    - Removed `LogitsBatchDivision.swift`, `LogitsBatchDivisionTests.swift` and `IndexedBatches.swift` (only `LogitsBatchDivision` and `EmbeddingBatchDivision` used it). `EmbeddingBatchDivision.swift` is the same as HEAD again (`git diff HEAD` is empty).
    - The real-model test "a call with mixed-length prompts gives exactly the values of one call for each prompt" asserts `together == alone` (exact equality). RED: it failed with the old batch code. GREEN: it passes with one prompt for each pass.
    - Card: the batching subtask and the batch acceptance criterion now have the text of the decision. The `logProbabilities` item now says "one forward pass for each prompt" (before: "for each batch"), so that it agrees with the decision.
  timestamp: 2026-11-10T20:24:56.680748+00:00
- actor: claude-code
  id: 01m73j59mbmxrccn8xe5hyv6yc
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsExtras/ModelPool/MLXLogits.swift (one prompt for each pass); removed LogitsBatchDivision.swift, IndexedBatches.swift, Tests/.../LogitsBatchDivisionTests.swift; EmbeddingBatchDivision.swift returned to HEAD; Tests/.../MLXLogitsRealModelTests.swift (exact equality). `EXTRAS_MLX_INTEGRATION=1 swift test --filter MLXLogitsRealModel`: 8 of 8 pass. `swift test --filter "MLXLogits|EmbeddingBatch"`: 29 tests in 4 suites pass, 0 failures, the real-model suite skipped without the flag. No Package.swift change.
    - next: /review
  timestamp: 2026-11-10T20:24:59.275043+00:00
- actor: claude-code
  id: 01m73jdaa09sh8r05yk42xf50y
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (972b0f4); 1 finding (1 confirmed, 4 refuted) — Sources/FoundationModelsExtras/ModelPool/MLXLogits.swift:163 completeness/invariant-propagation
    - next: add a test that gives a prompt token ID at or above the vocabulary size, with a valid candidate, and expects MLXLogitsError.tokenOutsideVocabulary. Then commit and review again.
  timestamp: 2026-11-10T20:29:22.112807+00:00
- actor: claude-code
  id: 01m73jdrrgq9kzrd0e8wsaehw2
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — MLXLogits.swift and 2 test files (one prompt for each pass, after the stuck report and the decision)
    - test: green — swift test, 7 runs, 0 failed
    - commit: 972b0f4
    - review: findings — Sources/FoundationModelsExtras/ModelPool/MLXLogits.swift:163
  timestamp: 2026-11-10T20:29:36.912468+00:00
- actor: claude-code
  id: 01m73jjfvpq3x2fx806zc7h0kk
  text: |-
    Worked the finding at MLXLogits.swift:163 (completeness/invariant-propagation).
    - Location: `candidateOutsideTheVocabularyThrows` is in `MLXLogitsRealModelTests.swift`, not in `MLXLogitsTests.swift`. The range check runs only after the model loads (it reads the logits width), so a unit test with the throwing loader cannot reach it. The new tests are next to `candidateOutsideTheVocabularyThrows` in the real-model suite.
    - Branch audit of the input checks: empty prompt, no candidates and no prompts already had unit tests. These branches had no test: a prompt token at or above the vocabulary size, a negative candidate, and a negative prompt token. Added `promptTokenOutsideTheVocabularyThrows`, `negativeCandidateThrows`, `negativePromptTokenThrows`, with one private helper `expectOutsideVocabulary` so the three tests share one body.
    - RED: a temporary change made the check read `candidates.first(where: { $0 >= vocabularySize })` (no prompt IDs, no lower limit). The 3 new tests failed (a value came back, no error) and `candidateOutsideTheVocabularyThrows` passed. The original check is back; `git diff Sources` is empty.
    - GREEN: `EXTRAS_MLX_INTEGRATION=1 swift test --filter MLXLogits`: 19 tests in 2 suites pass.
  timestamp: 2026-11-10T20:32:11.638584+00:00
- actor: claude-code
  id: 01m73jjq7wpkjegyfb6mmw2tsm
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsExtrasTests/ModelPool/MLXLogitsRealModelTests.swift (3 new tests, 1 helper). `swift test --filter MLXLogits`: 19 tests in 2 suites pass (real-model suite skipped without the flag). `EXTRAS_MLX_INTEGRATION=1 swift test --filter MLXLogits`: 19 tests in 2 suites pass, 0 failures. No change to Sources.
    - next: /review
  timestamp: 2026-11-10T20:32:19.196449+00:00
depends_on:
- 01M73FTQ8MB6JSDYYR9BYWJHBD
position_column: doing
position_ordinal: '80'
title: 'MLX conformance: extension MLXLanguageModel: PooledLogits'
---
## What
Make the MLX LLM container that `MLXModelLoader` gives for an `.llm` key (`MLXLanguageModel`, from `MLXFoundationModels` in the `mlx-swift-lm` fork) conform to `PooledLogits` (from `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`). Then `PooledLogitsModel(ref:)` works with the default pool.

Create `Sources/FoundationModelsExtras/ModelPool/MLXLogits.swift` with `extension MLXLanguageModel: PooledLogits`:
- [x] Get the container with the public `loadContainer()`. Do all model work inside `ModelContainer.perform`, which is the generation lock, so a logits call never runs at the same time as a generation on the same model.
- [x] `tokenize`: the tokenizer of the container with no special tokens added (no BOS, no EOS). Special-token text becomes the special token. `renderChatTemplate`: the chat template of the tokenizer as text, with the generation prompt; `reasoning: false` sets `enable_thinking: false` in the template context; `nil` when the tokenizer has no template. `maximumPromptTokens`: the context length of the model configuration, or `nil` when it is not known.
- [x] `logProbabilities`: one forward pass for each prompt, with no cache from an earlier call and no generated token. Read the logits of the last position only, apply log-softmax over the full vocabulary in Float32, then read the candidate columns. Throw an error for an empty prompt or for a candidate ID outside the vocabulary.
- [x] Run one prompt for each forward pass, in one `perform` call. A call with several prompts gives exactly the same values as one call for each prompt.

## Acceptance Criteria
- [x] `PooledLogitsModel(ref: "mlx-community/Qwen3-0.6B-4bit")` gives finite log probabilities that are all `<= 0`.
- [x] The sum of `exp` of the log probabilities of ALL vocabulary IDs at one position is 1 within 1e-3.
- [x] The same prompt gives the same values on a second call.
- [x] A call with mixed-length prompts gives exactly the same values (difference 0) as one call for each prompt.
- [x] No new target, product or dependency. No new warnings.

## Tests
- [x] Create `Tests/FoundationModelsExtrasTests/ModelPool/MLXLogitsRealModelTests.swift`. Gate the suite with `.enabled(if: ProcessInfo.processInfo.environment["EXTRAS_MLX_INTEGRATION"] == "1", "set EXTRAS_MLX_INTEGRATION=1")`, the same pattern as `Tests/FoundationModelsExtrasLlamaCppTests/LlamaCppRealModelTests.swift`. Use `mlx-community/Qwen3-0.6B-4bit`. Test the four criteria above, `tokenize` of `<|im_start|>` gives one token, and `renderChatTemplate(reasoning: false)` ends with the generation prompt.
- [x] Run `EXTRAS_MLX_INTEGRATION=1 swift test --filter MLXLogitsRealModel`. All tests pass.
- [x] Run `swift test`. All tests pass; the new suite is skipped without the flag.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision

## Review Findings (2026-11-10 14:27)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/FoundationModelsExtras/ModelPool/MLXLogits.swift:163` `completeness/invariant-propagation` — The vocabulary range check runs over both candidates and prompt tokens. The only test of this check, candidateOutsideTheVocabularyThrows, feeds an out-of-range candidate. No test feeds an out-of-range prompt token, so the prompt side of the same check has no coverage. A regression that drops prompt IDs from the check would pass every test. Add a test that passes a prompt containing a token ID equal to or above the vocabulary size, with a valid candidate, and asserts that MLXLogitsError.tokenOutsideVocabulary is thrown.
