---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73hkp177d8m1tzqnk67yb8t
  text: |-
    ### L1 is committed, but it is not pushed
    - FoundationModelsLlamaCpp commit 7c9c6270a579a15adaa1f5f6cc511e92373e823d on main. It is NOT on origin. Extras resolves FoundationModelsLlamaCpp by git URL (Package.resolved pins 0541b99), so this task cannot build until the commit is pushed. Keep the tag `waits-l1` until then. Then run `swift package update FoundationModelsLlamaCpp`.
    - API: `LlamaLanguageModel.logProbabilities(of: [Int], after: [[Int]]) async throws -> [[Double]]` (nonisolated(nonsending); full-vocabulary log-softmax; one prompt for each decode in its own empty sequence; no BOS added; generation lock; `[]` for no prompts).
    - `LlamaLanguageModel.contextSize: Int` → `maximumPromptTokens`.
    - `try model.tokenizer()` → `LlamaTokenizer` (synchronous): `tokens(_:parsesSpecialTokens: true) -> [Int32]` (no BOS/EOS; map to Int) → `tokenize`; `renderChatTemplate([LlamaChatMessage(role:content:)], reasoning:) -> String?` (an unknown role throws) → `renderChatTemplate`; `vocabularySize: Int`.
    - Errors: `LlamaError.emptyPrompt`, `LlamaError.tokenNotInVocabulary`, `LanguageModelError.contextSizeExceeded`.
    - For a vocabulary that adds BOS (Gemma), the rendered template starts with the BOS text. Do not add a second BOS.
  timestamp: 2026-11-10T20:15:22.151890+00:00
depends_on:
- 01M73FTQ8MB6JSDYYR9BYWJHBD
position_column: todo
position_ordinal: '8380'
title: 'llama.cpp conformance: extension LlamaLanguageModel: PooledLogits (waits for L1)'
---
## What
BLOCKED: this task waits for task L1 in FoundationModelsLlamaCpp. The session foundationmodelsllamacpp-ab sends the commit sha and the signatures of L1. Do not start this task before that message. When it comes, write the L1 signatures on this card, update the pin of FoundationModelsLlamaCpp if necessary, and remove the tag `waits-l1`.

Make `LlamaLanguageModel` (from `FoundationModelsLlamaCpp`) conform to `PooledLogits` (from `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`), so that `PooledLogitsModel(ref:pool:)` works with a pool that has the `LlamaCppModelLoader`.

Create `Sources/FoundationModelsExtrasLlamaCpp/LlamaLogits.swift` with `extension LlamaLanguageModel: PooledLogits`:
- [ ] `tokenize`, `renderChatTemplate`, `maximumPromptTokens` (the context size) through the L1 API. `tokenize` adds no BOS or EOS and parses special-token text.
- [ ] `logProbabilities`: one prompt for each decode. Do not put several prompts in one decode as separate sequences. Read the logits of the last position, apply log-softmax over the full vocabulary, then read the candidates. Clear the KV cache between prompts, so that each prompt is evaluated exactly as given.

## Acceptance Criteria
- [ ] `PooledLogitsModel` on `Mapika/decider-2b-GGUF` gives finite log probabilities that are all `<= 0`.
- [ ] The sum of `exp` over the full vocabulary at one position is 1 within 1e-3.
- [ ] The same prompt gives the same values on a second call, and the values of a prompt do not change when other prompts are in the same call.

## Tests
- [ ] Add a suite to `Tests/FoundationModelsExtrasLlamaCppTests/` (for example `LlamaLogitsRealModelTests.swift`), gated by `EXTRAS_GGUF_INTEGRATION=1` as `LlamaCppRealModelTests.swift` is. Test the three criteria above.
- [ ] Run `EXTRAS_GGUF_INTEGRATION=1 swift test --filter LlamaLogitsRealModel`. All tests pass.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- When this is committed, send foundationmodelsdecision-6f the commit sha. #decision