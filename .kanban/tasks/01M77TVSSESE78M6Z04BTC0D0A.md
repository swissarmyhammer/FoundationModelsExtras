---
assignees:
- claude-code
depends_on:
- 01M77TVABAGVCSJT7VKCF1A3XV
- 01M77TPTFW0730ECSJ2TTSAZW2
position_column: todo
position_ordinal: '8280'
title: 'llama.cpp native decisions: extension LlamaLanguageModel: PooledDecisions (waits for L3)'
---
## What
BLOCKED: this task waits for task L3 in FoundationModelsLlamaCpp (session foundationmodelsllamacpp-ab). L3 gives a public Swift decision API: the decision type of a GGUF file, and `decide` with the semantics of `llama-server POST /v1/systemone`. Do not start this task before L3 is on FoundationModelsLlamaCpp origin/main. Then write the L3 signatures on this card, run `swift package update FoundationModelsLlamaCpp`, and remove the tag `waits-l3`.

Make `LlamaLanguageModel` (from `FoundationModelsLlamaCpp`) conform to `PooledDecisions` (from `Sources/FoundationModelsExtras/ModelPool/PooledDecisions.swift`). Then `PooledDecisionsModel(ref:pool:)` works with a pool that has the `LlamaCppModelLoader`.

Create `Sources/FoundationModelsExtrasLlamaCpp/LlamaDecisions.swift` with `extension LlamaLanguageModel: PooledDecisions`. Use `Sources/FoundationModelsExtrasLlamaCpp/LlamaLogits.swift` as the model to follow.
- [ ] `decisionType()`: the decision type of the model from L3, or `nil` when the GGUF has no `decision.type`. A model with no decision type is thus not decision-capable, and `PooledDecisionsModel` throws `notDecisionCapable`.
- [ ] `maximumOptions()`: the limit from L3.
- [ ] `decide(state:questions:)`: map `PooledDecisionState`, `PooledDecisionQuestion` and `PooledDecisionOption` to the L3 types, call the L3 `decide`, and map each result to `PooledDecisionAnswer` (the probabilities in option order, and the expected value for a `score` question). Do not make a prompt or read logits in Extras: llama.cpp does that.

## Acceptance Criteria
- [ ] `PooledDecisionsModel` on `h2oai/h2o-lightning-4b-gguf` (`h2o-lightning-4b-Q4_K_M.gguf`) gives `decisionType()` `"h2o-lightning"` (or the name that L3 gives).
- [ ] For a `noul` question and a `choice` question, the probabilities of each answer are finite, each is in 0...1, and their sum is 1 within 1e-3. For a `score` question, `expectedValue` is not `nil`.
- [ ] The same state and questions give the same values on a second call.
- [ ] A GGUF with no decision type (for example the model of the llama.cpp loader integration test) throws `PooledDecisionsModelError.notDecisionCapable`.

## Tests
- [ ] Add `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/LlamaDecisionsIntegrationTests.swift`. Do not gate it with an environment variable: the CI of this repository runs real-model tests only from the `IntegrationTests/` package. The llama.cpp dependencies of that package come from the task that moves the llama.cpp suites there.
- [ ] Add unit tests that need no weights to `Tests/FoundationModelsExtrasLlamaCppTests/LlamaDecisionsTests.swift`, for the mapping of each type.
- [ ] Run `swift test --package-path IntegrationTests` and `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- When this is on origin/main and CI is green, send foundationmodelsdecision-6f the sha and the CI run. #decision #waits-l3