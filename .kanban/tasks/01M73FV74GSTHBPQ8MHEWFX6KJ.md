---
assignees:
- claude-code
depends_on:
- 01M73FTQ8MB6JSDYYR9BYWJHBD
position_column: todo
position_ordinal: '8180'
title: 'MLX conformance: extension MLXLanguageModel: PooledLogits'
---
## What
Make the MLX LLM container that `MLXModelLoader` gives for an `.llm` key (`MLXLanguageModel`, from `MLXFoundationModels` in the `mlx-swift-lm` fork) conform to `PooledLogits` (from `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`). Then `PooledLogitsModel(ref:)` works with the default pool.

Create `Sources/FoundationModelsExtras/ModelPool/MLXLogits.swift` with `extension MLXLanguageModel: PooledLogits`:
- [ ] Get the container with the public `loadContainer()`. Do all model work inside `ModelContainer.perform`, which is the generation lock, so a logits call never runs at the same time as a generation on the same model.
- [ ] `tokenize`: the tokenizer of the container with no special tokens added (no BOS, no EOS). Special-token text becomes the special token. `renderChatTemplate`: the chat template of the tokenizer as text, with the generation prompt; `reasoning: false` sets `enable_thinking: false` in the template context; `nil` when the tokenizer has no template. `maximumPromptTokens`: the context length of the model configuration, or `nil` when it is not known.
- [ ] `logProbabilities`: one forward pass for each batch, with no cache from an earlier call and no generated token. Read the logits of the last position only, apply log-softmax over the full vocabulary in Float32, then read the candidate columns. Throw an error for an empty prompt or for a candidate ID outside the vocabulary.
- [ ] Batching: put prompts in batches of up to 16. The results MUST be equal to the results of one-by-one calls. Use this approach: in each batch, put only prompts of the same length together, so that no padding is necessary. When this is not possible, run the prompt alone. Do not use padding.

## Acceptance Criteria
- [ ] `PooledLogitsModel(ref: "mlx-community/Qwen3-0.6B-4bit")` gives finite log probabilities that are all `<= 0`.
- [ ] The sum of `exp` of the log probabilities of ALL vocabulary IDs at one position is 1 within 1e-3.
- [ ] The same prompt gives the same values on a second call.
- [ ] A batch of mixed-length prompts gives the same values (within 1e-4) as one call for each prompt.
- [ ] No new target, product or dependency. No new warnings.

## Tests
- [ ] Create `Tests/FoundationModelsExtrasTests/ModelPool/MLXLogitsRealModelTests.swift`. Gate the suite with `.enabled(if: ProcessInfo.processInfo.environment["EXTRAS_MLX_INTEGRATION"] == "1", "set EXTRAS_MLX_INTEGRATION=1")`, the same pattern as `Tests/FoundationModelsExtrasLlamaCppTests/LlamaCppRealModelTests.swift`. Use `mlx-community/Qwen3-0.6B-4bit`. Test the four criteria above, `tokenize` of `<|im_start|>` gives one token, and `renderChatTemplate(reasoning: false)` ends with the generation prompt.
- [ ] Run `EXTRAS_MLX_INTEGRATION=1 swift test --filter MLXLogitsRealModel`. All tests pass.
- [ ] Run `swift test`. All tests pass; the new suite is skipped without the flag.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision