---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78hdmd5ana58q1vttr55cb7
  text: |-
    ### Contract points from the consumer (foundationmodelsdecision-6f)
    1. `PooledDecisionOption.description` is `String?`.
    2. `noul`: always two options with the keys "true" and "false", in the order that the caller gives; `probabilities` follows that order; descriptions can be nil; an empty option list is not valid.
    3. `score`: the options are the levels, lowest first, with the keys "0" to "n-1"; `expectedValue` is in level-index units (0 to n-1); `probabilities` follows the level order.
    4. `PooledDecisionState.json(String)` holds JSON text, which Extras passes unchanged (no parse, no change of key order).
    These are documentation of the contract. `PooledDecisionsModel` does not validate them; the container decides.
  timestamp: 2026-11-12T18:48:16.037359+00:00
- actor: claude-code
  id: 01m78hf1nccat89g5b5wt0fy3n
  text: 'Research: `PooledLogitsModel` uses `ResidentHold<LoadedLogits>`; `init(ref:pool:)` loads in the closure, `init(hold:)` uses `ResidentHold(loaded:)`. Plan for decisions: `LoadedDecisions` casts the container; the decision-type check runs inside a `ResidentHold` load closure for both inits (for `init(hold:)` the closure captures the already-cast hold). Thus the check runs one time only, also for concurrent first calls, and a named model with a nil decision type keeps no hold. `init(hold:)` is synchronous, so it can only check conformance; the `decisionType()` check comes on the first call. Card subtask for `PooledDecisionOption` edited to `description: String?` (consumer contract).'
  timestamp: 2026-11-12T18:49:02.380665+00:00
- actor: claude-code
  id: 01m78hn0b75jqjwpbwcqm9f05p
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsExtras/ModelPool/PooledDecisions.swift (new), Tests/FoundationModelsExtrasTests/ModelPool/PooledDecisionsModelTests.swift (new, 18 tests), Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift (FakeDecisions), docs/REFERENCE.md (new section "Native decisions: `PooledDecisionsModel`"). RED: compile failed on the missing types. `swift test --filter PooledDecisionsModel`: 18 of 18 pass. Full `swift test`: all suites pass, no compiler warnings. Consumer contract points 1-4 are in the doc comments and REFERENCE.md, with no validation in the model. The decision-type check runs one time in the `ResidentHold` load closure for both inits; `LoadedDecisions.hold` is read in `checkedDecisionType()` and in `init(hold:)` for `ref`.
    - next: /review
  timestamp: 2026-11-12T18:52:17.639874+00:00
position_column: doing
position_ordinal: '80'
title: PooledDecisions protocol and PooledDecisionsModel (a .llm hold that answers decision questions natively)
---
## What
Some GGUF models carry a decision type in their metadata (`{arch}.decision.type`). llama.cpp makes the prompt and reads the answer for these models. FoundationModelsDecision (`PooledNativeDecisionModel`) and the Router use this path through Extras. Extras must NOT depend on FoundationModelsDecision, so this API uses plain Swift types only. Do not change `Package.swift`.

Create `Sources/FoundationModelsExtras/ModelPool/PooledDecisions.swift`, next to `PooledLogits.swift`. Use the same pattern as `PooledLogitsModel` in `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift` (`ResidentHold`, a private `Loaded…` struct that casts `hold.container`). Use the prefix `Pooled` on each type, so that the names do not clash with the types of FoundationModelsDecision.

- [x] Plain value types, each `Sendable` and `Hashable`:
  - `public enum PooledDecisionState { case text(String), json(String) }`: the state that the questions are about.
  - `public enum PooledDecisionQuestionType: String { case choice, score, noul }`.
  - `public struct PooledDecisionOption { public var key: String; public var description: String? }`.
  - `public struct PooledDecisionQuestion { public var id: String; public var type: PooledDecisionQuestionType; public var instructions: String; public var options: [PooledDecisionOption] }`.
  - `public struct PooledDecisionAnswer { public var id: String; public var probabilities: [Double]; public var expectedValue: Double? }`: one probability for each option, in option order. `expectedValue` is the expected value of a `score` question, and `nil` for other types.
  - Each type has a public memberwise `init`.
- [x] `public protocol PooledDecisions: Sendable` with:
  - `func decisionType() async throws -> String?`: the decision type name of the model, or `nil` when the model has no decision type.
  - `func maximumOptions() async throws -> Int`: the largest number of options in one question.
  - `func decide(state: PooledDecisionState, questions: [PooledDecisionQuestion]) async throws -> [PooledDecisionAnswer]`: one answer for each question, in question order.
  - Use functions, not properties: `PooledDecisionsModel(ref:)` loads the model on the first call, so a property would have no value before the load.
- [x] `public struct PooledDecisionsModel: PooledDecisions` with `public let ref: ModelRef`, `public init(ref: ModelRef, pool: ModelPool = .shared)` (loads nothing; the first call acquires a `ModelPoolKey(ref: ref, role: .llm)` hold, one time only) and `public init(hold: ModelHold) throws`. It keeps the hold alive while a copy of the model exists, and forwards each call to the container.
- [x] `public enum PooledDecisionsModelError: Error, Equatable, LocalizedError { case notDecisionCapable(ModelRef) }`. The model throws it when the container does not conform to `PooledDecisions`, or when its `decisionType()` gives `nil`. `init(hold:)` throws it for a container that does not conform. The first call of a model made from a ref also checks `decisionType()`.
- [x] Docs: add a section "Native decisions: `PooledDecisionsModel`" to `docs/REFERENCE.md`, after "Log probabilities: `PooledLogitsModel`".

## Acceptance Criteria
- [x] A hold whose container conforms and has a decision type gives a `PooledDecisionsModel` that returns the values of the container for all three functions.
- [x] A container that does not conform makes `init(hold:)` throw `notDecisionCapable(ref)`. A model made from a ref throws the same error on its first call.
- [x] A container that conforms but gives `nil` from `decisionType()` makes the first `decide` and `maximumOptions` call throw `notDecisionCapable(ref)`.
- [x] Two first calls at the same time acquire the model one time only, and the hold is released when the last copy goes away.
- [x] No new target, product or dependency. No new warnings.

## Tests
- [x] Create `Tests/FoundationModelsExtrasTests/ModelPool/PooledDecisionsModelTests.swift` (Swift Testing). Add a `FakeDecisions: PooledDecisions` stub to `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift`, with a settable decision type (also `nil`), and use `FixedLoader` / `RecordingLoader`. Test each criterion above.
- [x] Run `swift test --filter PooledDecisionsModel`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- When this is on origin/main and CI is green, send foundationmodelsdecision-6f the sha and the CI run. #decision