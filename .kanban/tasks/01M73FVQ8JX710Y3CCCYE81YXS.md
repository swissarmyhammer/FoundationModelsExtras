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
- actor: claude-code
  id: 01m73m1tq4fcrdae6cj34gg5t1
  text: |-
    ### Research
    - The worktree branch did not have PooledLogits. Merged local main (a346284..43522bb) into the branch: commit 0859c9a.
    - `swift package update FoundationModelsLlamaCpp` pins 7c9c6270a579a15adaa1f5f6cc511e92373e823d. Package.resolved is in .gitignore, thus no commit holds it.
    - The cache holds `Mapika/decider-2b-GGUF` at 0df001b8fe4e5298c5dd45d875d3795fcdaea0ab, file `decider-2b-v12-Q4_K_M.gguf` (Qwen3.5-2B base, Qwen3.5 chat template).
    - The vocab-only file `qwen35` and the template `Qwen3.5-4B` of LlamaCppTestFixtures let hermetic tests examine tokenize, renderChatTemplate and maximumPromptTokens with no weights.
    - Possible conflict: the validator `test-integrity/test-partitioning` forbids an environment variable that selects tests, and asks for the nested package `IntegrationTests/`. The card orders the gate `EXTRAS_GGUF_INTEGRATION=1` in `Tests/FoundationModelsExtrasLlamaCppTests/`. I follow the card. If review reports this rule, it is a true conflict.
  timestamp: 2026-11-10T20:58:02.852211+00:00
- actor: claude-code
  id: 01m73mhfh22xt9z3bf7yfpckaj
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files: Sources/FoundationModelsExtrasLlamaCpp/LlamaLogits.swift, Tests/FoundationModelsExtrasLlamaCppTests/LlamaLogitsTests.swift (9 hermetic tests, vocab-only Qwen3.5 fixture), Tests/FoundationModelsExtrasLlamaCppTests/LlamaLogitsRealModelTests.swift (5 tests, Mapika/decider-2b-GGUF@0df001b). The L1 method `logProbabilities(of:after:)` satisfies the requirement with no wrapper. A message with no "role" or no "content" throws `LlamaLogitsError.messageWithoutKey(_:index:)`.
    - test: green — `swift test`: 401 + 1837 + 27 tests passed, 0 failed, exit 0. `EXTRAS_GGUF_INTEGRATION=1 swift test --filter LlamaLog`: 14 tests in 2 suites passed, 0 skipped. The skips of the default run are the suites that the environment gates (MLX and GGUF real models), as the card orders.
    - commit: changed — 0d6d8e0 feat(llama-cpp): LlamaLanguageModel gives log probabilities as a PooledLogits (after the merge of main, 0859c9a).
    - review: clean — `review sha 0859c9a..0d6d8e0`: 3 files, 0 findings, 0 confirmed, 2 refuted. Note: `review sha HEAD~1..HEAD` resolved in the main checkout (124f749..43522bb), thus the explicit shas were necessary. The tool rules of code-hygiene found no file (they read the main checkout). I ran them in the worktree: swiftlint (no_magic_numbers, force_*, function/closure length) exit 0; swift format lint (the 7 idiom rules and AllPublicDeclarationsHaveDocumentation) gives no finding.
    - next: send foundationmodelsdecision-6f the sha 0d6d8e0 (the parent session relays it). Not pushed.
  timestamp: 2026-11-10T21:06:35.682826+00:00
depends_on:
- 01M73FTQ8MB6JSDYYR9BYWJHBD
position_column: done
position_ordinal: ffe180
title: 'llama.cpp conformance: extension LlamaLanguageModel: PooledLogits (waits for L1)'
---
## What
L1 is pushed: FoundationModelsLlamaCpp origin/main 7c9c6270a579a15adaa1f5f6cc511e92373e823d. The L1 signatures are in the comment "L1 is committed, but it is not pushed". Package.resolved pins 7c9c627 (the file is in .gitignore).

Make `LlamaLanguageModel` (from `FoundationModelsLlamaCpp`) conform to `PooledLogits` (from `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`), so that `PooledLogitsModel(ref:pool:)` works with a pool that has the `LlamaCppModelLoader`.

Create `Sources/FoundationModelsExtrasLlamaCpp/LlamaLogits.swift` with `extension LlamaLanguageModel: PooledLogits`:
- [x] `tokenize`, `renderChatTemplate`, `maximumPromptTokens` (the context size) through the L1 API. `tokenize` adds no BOS or EOS and parses special-token text.
- [x] `logProbabilities`: one prompt for each decode. Do not put several prompts in one decode as separate sequences. Read the logits of the last position, apply log-softmax over the full vocabulary, then read the candidates. Clear the KV cache between prompts, so that each prompt is evaluated exactly as given.

## Acceptance Criteria
- [x] `PooledLogitsModel` on `Mapika/decider-2b-GGUF` gives finite log probabilities that are all `<= 0`.
- [x] The sum of `exp` over the full vocabulary at one position is 1 within 1e-3.
- [x] The same prompt gives the same values on a second call, and the values of a prompt do not change when other prompts are in the same call.

## Tests
- [x] Add a suite to `Tests/FoundationModelsExtrasLlamaCppTests/` (for example `LlamaLogitsRealModelTests.swift`), gated by `EXTRAS_GGUF_INTEGRATION=1` as `LlamaCppRealModelTests.swift` is. Test the three criteria above.
- [x] Run `EXTRAS_GGUF_INTEGRATION=1 swift test --filter LlamaLogitsRealModel`. All tests pass.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- When this is committed, send foundationmodelsdecision-6f the commit sha. #decision