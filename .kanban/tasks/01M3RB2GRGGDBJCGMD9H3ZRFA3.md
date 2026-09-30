---
position_column: todo
position_ordinal: '80'
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
- [ ] The mask of each row has one 1 for each real token, the end token included, and 0 for each pad.
- [ ] A text embedded in a batch with longer texts gives the same vector as the text alone (cosine ≥ 0.999).
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/EmbeddingBatchPaddingTests.swift`: the helper on a right-padded batch that includes a row whose last real token equals the pad (end) token: padded rows and mask are correct.
- [ ] `IntegrationTests/.../PooledEmbedderIntegrationTests.swift`: with `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`, each text of a batch of three texts of different lengths has cosine ≥ 0.999 with the same text embedded alone.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool