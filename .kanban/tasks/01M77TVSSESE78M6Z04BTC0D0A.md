---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78yvc5xbb2j60zke7kyx4za
  text: |-
    ### L3 is on origin/main
    - FoundationModelsLlamaCpp f32709ee2c2b8418ff205e076f184d6c7804e1cc; it needs llama-cpp-swift main 90ddcdf or later (both on origin/main). L3 CI run 43322283340 was queued on 2026-11-12. Do not push this task before that run is green.
    - API: `LlamaDecisionType` (String raw values as llama.cpp, for example "h2o-lightning"; `static func read(from: URL) throws -> LlamaDecisionType?`; `var isSupportedByDecide: Bool`). `LlamaLanguageModel.decisionType: LlamaDecisionType?`. `LlamaLanguageModel.decide(state: LlamaDecisionState, questions: [LlamaDecisionQuestion]) async throws -> [LlamaDecisionAnswer]` (nonisolated(nonsending); answers in question order).
    - `LlamaDecisionState { text(String), json(String) }`. `LlamaDecisionOption(key:description: String? = nil)`. `LlamaDecisionQuestion(id:kind:instructions: String?, options:)` with `Kind { choice, score, noul }`.
    - `LlamaDecisionAnswer { questionID, probabilities: [Double] (option order, after temperature; noul: [1 - noul, noul]), outcome: .choice(key:confidence:) | .score(value:confidence:legend:) | .noul(Double) }`.
    - Errors: `LlamaError.notDecisionModel`, `.unsupportedDecisionType(_)`, `.decisionRequestNotValid(reason:)`, `.imageInputNotSupported`.

    ### Mapping rules (from foundationmodelsdecision-6f)
    - `decisionType()` gives `decisionType?.rawValue` when `isSupportedByDecide`, else `nil`.
    - `noul`: L3 gives `[false, true]` order, not the caller order. Build `probabilities` from `.noul(p)` in the order of the caller's option keys ("true" → p, "false" → 1 - p). Test both orders.
    - `score`: `expectedValue` is `.score(value:)`. Check that it is in level-index units 0...n-1; if L3 gives another unit, convert it and write the reason in a doc comment.
    - For `lev`, `noul` is an expected rating from 0 to 1, not a true probability (the same as llama-server). Write this in a doc comment.

    ### Open point: maximumOptions() — CLOSED BY REMOVAL
    - User decision (relayed by the coordinator): do not check limits before a call, and do not add an API only to prevent an error. `maximumOptions()` is removed from `PooledDecisions`, `PooledDecisionsModel`, `FakeDecisions`, PooledDecisionsModelTests.swift and the "Native decisions" section of docs/REFERENCE.md. `LlamaDecisions.swift` does not implement it.
    - `decide` passes the error of L3 to the caller unchanged: llama.cpp (`server_decision_context::n_options_max` in server-decision.cpp) throws "too many options (N), this model supports at most M", which L3 gives as `LlamaError.decisionRequestNotValid(reason:)`. The doc comment of `PooledDecisions.decide` says that a request the model cannot do throws the error of the model. An integration test sends 300 options and expects that error.
    - (Superseded: an earlier decision returned 255 as an upper bound.)

    ### Build risk (from foundationmodelsllamacpp-ab)
    - With Swift 6.4.2, `String(_: std.string)` from CxxStdlib can fail in a clean build ("no exact matches in call to initializer"). Use `String(describing:)`.
  timestamp: 2026-11-12T22:42:57.853826+00:00
- actor: claude-code
  id: 01m78za7dhh1w2v61jwemy5ge0
  text: |-
    ### Research and implementation notes
    - Pins after `swift package update` (root and IntegrationTests): FoundationModelsLlamaCpp f32709e, llama-cpp-swift 90ddcdf.
    - `LlamaDecisionAnswer` has no public initializer, thus the unit tests cannot make one. The answer map is `PooledDecisionAnswer.init(question:probabilities:outcome:)` (internal): the `Outcome` cases are public, thus the tests make each outcome. The wrapper in `decide` only forwards `answer.probabilities` and `answer.outcome`. The integration test covers the real `decide`.
    - Score: L3 reads `score` of llama.cpp `format_answer`, and the doc of `Outcome.score` says it is the sum of each level number from 0 times its probability. That is level-index units, thus no conversion. The integration test checks 0...n-1.
    - Noul: llama.cpp reads only the keys "false" and "true" of the criteria (h2o-lightning also reads "no"/"yes" descriptions). Extras now refuses a noul question that does not have exactly the two keys "true" and "false", with the new `LlamaDecisionsError.noulOptionsNotValid(questionID:)`, before the model runs. Without this check, the map of the answer to the caller key order has no meaning for another key.
    - The property `LlamaLanguageModel.decisionType` and the protocol method `decisionType()` live together with no clash (the method is in another module). Inside the method, `(decisionType as LlamaDecisionType?)` selects the property.
    - The integration test pins h2oai/h2o-lightning-4b-gguf at 61f8d8b7a8c2d84426d0d143ca187f65d235934b (Q4_K_M, 2.7 GB). The model with no decision type is Qwen3.5-0.8B (`singleFileRef` of LlamaCppIntegrationTests.swift, now internal so the two suites share it).
  timestamp: 2026-11-12T22:51:04.497534+00:00
- actor: claude-code
  id: 01m7951ppkvpdyq1dva91gvhft
  text: |-
    ### Dependent package breaks: FoundationModelsDecision uses maximumOptions()
    - The removal of `PooledDecisions.maximumOptions()` breaks FoundationModelsDecision: `Sources/FoundationModelsDecision/NativeDecisionModel.swift`, `Sources/FoundationModelsDecision/NativeDecisionSource.swift` and `Tests/FoundationModelsDecisionTests/NativeDecisionModelTests.swift` name it. That package must change in the same release (foundationmodelsdecision-6f). This task does not edit that repository.
    - Open question for the coordinator: `LlamaDecisions.swift` refuses a noul question whose option keys are not exactly "true" and "false" (`LlamaDecisionsError.noulOptionsNotValid(questionID:)`), before the call. The reason is correctness, not a limit: llama.cpp ignores other keys (for example "yes"/"no") and still answers, and then the map of `.noul(p)` to the caller key order has no meaning. If the new rule ("no check of your own") also covers this, remove the check and the error type.
    - Integration run: waits for the shared download of h2o-lightning-4b Q4_K_M (revision 61f8d8b7a8c2d84426d0d143ca187f65d235934b) by another session; my run starts when the blob is complete. No second download was started.
  timestamp: 2026-11-13T00:31:16.691584+00:00
- actor: claude-code
  id: 01m795m9j37r7gse10ambjgb44
  text: |-
    ### FoundationModelsLlamaCpp 4f75615: answers by question ID
    - Root and IntegrationTests now pin FoundationModelsLlamaCpp 4f75615 (llama-cpp-swift 90ddcdf).
    - `decide` no longer pairs answers with questions by position. `PooledDecisionAnswer.answers(of:to:)` finds the question of each llama.cpp answer by `questionID`; for a repeated ID it uses the LAST question with that ID (the content that llama.cpp used). The answers keep the order of llama.cpp. No check or error of our own for repeats. An answer whose ID has no question (an L3 defect) gets `assertionFailure` and an `os.Logger` error, and is dropped: the LlamaCpp target has no `Logging` dependency, and the root Package.swift must not change.
    - `LlamaDecisionAnswer` has no public initializer, thus a small internal `LlamaDecisionResult` (questionID, probabilities, outcome) carries the parts that the map reads. The unit tests make it directly.
    - New unit tests: answers in an order different from the questions; a repeated ID uses the options of the last question.
    - Docs: `PooledDecisions.decide`, `LlamaLanguageModel.decide(state:questions:)` (the PooledDecisions one) and the "Native decisions" section of docs/REFERENCE.md say: give each question a different ID to get one answer for each question; a repeated ID gives fewer answers; a repeated option key can make the probabilities sum to more than 1.
    - Root `swift test`: all pass (1848 + 401 + 136 + 46 + 40 + 34 + 26 tests). Integration run still waits for the shared h2o download.
  timestamp: 2026-11-13T00:41:25.827863+00:00
- actor: claude-code
  id: 01m79652tbbq8sysz508dgdrag
  text: |-
    ### implement — changed
    - evidence: `swift test` (root) exit 0: 1848 + 401 + 136 + 46 + 40 + 34 + 26 tests pass (LlamaDecisionsTests 16, PooledDecisionsModelTests pass). `swift test --package-path IntegrationTests` exit 0: 63 tests in 16 suites pass in 334.7 s, with "LlamaCpp decisions with a real model" (6 tests, with the 300-option error test) and "LlamaCpp decisions with a real model that has no decision type". Pins: FoundationModelsLlamaCpp 4f75615, llama-cpp-swift 90ddcdf. The only build warning is SwiftPM "missing creator for mutated node" for the mlx-swift_Cmlx.bundle build product; no source file gives it.
    - files: Sources/FoundationModelsExtrasLlamaCpp/LlamaDecisions.swift (new), Sources/FoundationModelsExtras/ModelPool/PooledDecisions.swift, docs/REFERENCE.md, Tests/FoundationModelsExtrasLlamaCppTests/LlamaDecisionsTests.swift (new), Tests/FoundationModelsExtrasTests/ModelPool/PooledDecisionsModelTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/LlamaDecisionsIntegrationTests.swift (new), IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/LlamaCppIntegrationTests.swift (`singleFileRef` is now internal).
    - open: FoundationModelsDecision names `maximumOptions()` and must change with this release. The noul key check (`LlamaDecisionsError.noulOptionsNotValid`) waits for a coordinator decision.
    - next: /review
  timestamp: 2026-11-13T00:50:35.979519+00:00
depends_on:
- 01M77TVABAGVCSJT7VKCF1A3XV
- 01M77TPTFW0730ECSJ2TTSAZW2
position_column: doing
position_ordinal: '80'
title: 'llama.cpp native decisions: extension LlamaLanguageModel: PooledDecisions (waits for L3)'
---
## What
BLOCKED: this task waits for task L3 in FoundationModelsLlamaCpp (session foundationmodelsllamacpp-ab). L3 gives a public Swift decision API: the decision type of a GGUF file, and `decide` with the semantics of `llama-server POST /v1/systemone`. Do not start this task before L3 is on FoundationModelsLlamaCpp origin/main. Then write the L3 signatures on this card, run `swift package update FoundationModelsLlamaCpp`, and remove the tag `waits-l3`.

Make `LlamaLanguageModel` (from `FoundationModelsLlamaCpp`) conform to `PooledDecisions` (from `Sources/FoundationModelsExtras/ModelPool/PooledDecisions.swift`). Then `PooledDecisionsModel(ref:pool:)` works with a pool that has the `LlamaCppModelLoader`.

Create `Sources/FoundationModelsExtrasLlamaCpp/LlamaDecisions.swift` with `extension LlamaLanguageModel: PooledDecisions`. Use `Sources/FoundationModelsExtrasLlamaCpp/LlamaLogits.swift` as the model to follow.
- [x] `decisionType()`: the decision type of the model from L3, or `nil` when the GGUF has no `decision.type`. A model with no decision type is thus not decision-capable, and `PooledDecisionsModel` throws `notDecisionCapable`.
- [x] `maximumOptions()`: removed from `PooledDecisions`, `PooledDecisionsModel`, the test fake and docs/REFERENCE.md (user decision). Extras does not check limits before a call: `decide` gives the error of llama.cpp unchanged (`LlamaError.decisionRequestNotValid(reason:)`, "too many options (N), this model supports at most M").
- [x] `decide(state:questions:)`: map `PooledDecisionState`, `PooledDecisionQuestion` and `PooledDecisionOption` to the L3 types, call the L3 `decide`, and map each result to `PooledDecisionAnswer` (the probabilities in option order, and the expected value for a `score` question). Do not make a prompt or read logits in Extras: llama.cpp does that.

## Acceptance Criteria
- [x] `PooledDecisionsModel` on `h2oai/h2o-lightning-4b-gguf` (`h2o-lightning-4b-Q4_K_M.gguf`) gives `decisionType()` `"h2o-lightning"` (or the name that L3 gives).
- [x] For a `noul` question and a `choice` question, the probabilities of each answer are finite, each is in 0...1, and their sum is 1 within 1e-3. For a `score` question, `expectedValue` is not `nil`.
- [x] The same state and questions give the same values on a second call.
- [x] A GGUF with no decision type (for example the model of the llama.cpp loader integration test) throws `PooledDecisionsModelError.notDecisionCapable`.

## Tests
- [x] Add `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/LlamaDecisionsIntegrationTests.swift`. Do not gate it with an environment variable: the CI of this repository runs real-model tests only from the `IntegrationTests/` package. The llama.cpp dependencies of that package come from the task that moves the llama.cpp suites there.
- [x] Add unit tests that need no weights to `Tests/FoundationModelsExtrasLlamaCppTests/LlamaDecisionsTests.swift`, for the mapping of each type.
- [x] Run `swift test --package-path IntegrationTests` and `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- When this is on origin/main and CI is green, send foundationmodelsdecision-6f the sha and the CI run. #decision