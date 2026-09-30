---
comments:
- actor: claude-code
  id: 01m3rbd373rdw25hd42ge9053s
  text: |-
    Research:
    - The bug is in `MLXEmbedding.embed(texts:in:)` in Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift. The model mask is `padded .!= padToken`, and the pooling gets no mask.
    - MLXEmbedders `Pooling.callAsFunction(_:mask:normalize:applyLayerNorm:)`: with no mask, the pooling uses a mask of all ones. `.last` then takes the last column, which is a pad token for a short row. With a mask, `.last` takes the index `sum(mask) - 1`, and `.mean` divides by `sum(mask)`.
    - The Qwen3 embedder reads `attentionMask` as "nonzero = attend, zero = pad", and folds it into the causal mask.
    - ../FoundationModelsRouter has no copy of the fix in its tree (no match for `attentionMask` or `pooling(`). I do not use it.
    - Plan: a new internal value type `EmbeddingBatchPadding` in its own file (no MLX import). It right-pads `[[Int]]` rows and makes a `[[Int]]` mask from the length of each row. `MLXEmbedding` makes one Int32 `MLXArray` mask from it, and gives it to the model and to the pooling.
  timestamp: 2026-09-30T05:08:10.595138+00:00
- actor: claude-code
  id: 01m3rbx6er5ag2kryn8wn2xp2h
  text: |-
    Implementation landed (TDD):
    - RED, integration: `swift test --package-path IntegrationTests --filter batchVectorEqualsVectorOfTextAlone` failed with cosines [0.6445217, 0.6907059, 1.0000001] (floor 0.999).
    - RED, unit: `swift test --filter EmbeddingBatchPaddingTests` did not compile: "cannot find 'EmbeddingBatchPadding' in scope".
    - GREEN: new internal `EmbeddingBatchPadding(rows:padToken:)` (Sources/FoundationModelsExtras/ModelPool/EmbeddingBatchPadding.swift) gives `tokens` and `mask` ([[Int]]). `MLXEmbedding.embed(texts:in:)` stacks the mask as an MLXArray and gives it to `attentionMask:` and to `context.pooling(output, mask: mask, normalize: true, applyLayerNorm: true)`. The unit tests (3) and the new integration test pass.
    - CHANGELOG.md has a "Fixed" entry.
    - Full runs: `swift test` 840 tests in 83 suites passed (4 known issues: the existing `withKnownIssue` checks of TelemetryCaptureTests). `swift test --package-path IntegrationTests` 30 tests in 8 suites passed.
    - Note: each build prints the SwiftPM warning "missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS". It was there in the RED run before the code change. It comes from the build of the MLX bundle, not from a source file.
    - Open: "CI is green on the pushed commit". The orchestrator commits and pushes, then tells the Router session (foundationmodelsrouter-d5) the revision.
  timestamp: 2026-09-30T05:16:58.200173+00:00
- actor: claude-code
  id: 01m3rbxa0r318bw8ngjyzmx066
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/ModelPool/EmbeddingBatchPadding.swift (new), Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift, Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchPaddingTests.swift (new), IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift, CHANGELOG.md. `swift test`: 840 tests / 83 suites passed. `swift test --package-path IntegrationTests`: 30 tests / 8 suites passed.
    - next: /review. Then commit, push, CI, and send the revision to the Router session.
  timestamp: 2026-09-30T05:17:01.848112+00:00
- actor: claude-code
  id: 01m3rcd4srcm50cnxxg8w2kvsv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (0b487c6). Counts: 0 findings, 0 confirmed, 0 refuted, 7 validator runs attempted, 0 failed. The engine reviewed 4 files. The `.reviewignore` file excludes the 4 `.kanban/` files. No validator matches CHANGELOG.md.
    - Acceptance criteria against the code: `EmbeddingBatchPadding(rows:padToken:)` makes the mask from the length of each row (1 for each real token, the end token included, 0 for each pad). `MLXEmbedding.embed(texts:in:)` gives the same mask to `attentionMask:` and to `context.pooling(output, mask: mask, normalize: true, applyLayerNorm: true)`.
    - Tests against the code: `EmbeddingBatchPaddingTests` has a short row whose last real token equals the pad token, and it checks the padded rows and the mask. `batchVectorEqualsVectorOfTextAlone` embeds three texts of different lengths and checks cosine ≥ 0.999 for each text.
    - Open: "CI is green on the pushed commit". The orchestrator does the push, the CI check, and the message to the Router session.
    - next: the orchestrator pushes, checks CI, and sends the revision to the Router session (foundationmodelsrouter-d5).
  timestamp: 2026-09-30T05:25:40.792446+00:00
- actor: claude-code
  id: 01m3rcdgcn667hye426bp5qyat
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files
    - test: green — swift test 840 pass; swift test --package-path IntegrationTests 30 pass
    - commit: 0b487c6
    - review: clean — 0 findings
    - push: origin main; revision sent to foundationmodelsrouter-d5
  timestamp: 2026-09-30T05:25:52.661187+00:00
position_column: done
position_ordinal: de80
title: 'MLXEmbedding: mask pad tokens by row length in the model and in the pooling'
---
**Blocks:** FoundationModelsRouter task 01M3QMDDGWZ7CRAE1P3JKFP5FP (^jkfp5fp) through its task 01M3RAZRZV5JVTFD960AP5256J (^ap5256j, the full bug report). Tell the Router session (foundationmodelsrouter-d5) the pushed revision.

## What
A batch embed gives wrong vectors for each row shorter than the longest row. The Router integration test `batchVectorEqualsVectorOfTextAlone` shows cosines `[0.438, 0.275, 1.0]` between a text embedded in a batch and alone (the floor is 0.999).

Cause, in `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`, `MLXEmbedding.embed(texts:in:)`:
1. `context.pooling(output, normalize: true, applyLayerNorm: true)` gets no mask. With `.last` pooling (the Qwen3 embedders), a short row pools the hidden state of a pad token.
2. The model mask is `padded .!= padToken`, and the pad token is `eosTokenId`. So the mask also removes the real end token that `addSpecialTokens: true` adds.

Fix:
- Build the mask from the length of each row: 1 for each real token, 0 for each pad.
- Give that mask to the model (`attentionMask:`) and to the pooling (`context.pooling(output, mask: mask, normalize: true, applyLayerNorm: true)`).
- Put the padding and the mask in a helper that works on plain Swift arrays (`[[Int]]` in, padded rows and a `[[Int]]` mask out), so a unit test can read it without MLX.
- Push to `origin main` when green, and send the revision to the Router session.

## Acceptance Criteria
- [x] The mask of each row has one 1 for each real token, the end token included, and 0 for each pad.
- [x] A text embedded in a batch with longer texts gives the same vector as the text alone (cosine ≥ 0.999).
- [ ] CI is green on the pushed commit.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchPaddingTests.swift`: the helper on a right-padded batch that includes a row whose last real token equals the pad (end) token: padded rows and mask are correct.
- [x] `IntegrationTests/.../PooledEmbedderIntegrationTests.swift`: with `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`, each text of a batch of three texts of different lengths has cosine ≥ 0.999 with the same text embedded alone.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool