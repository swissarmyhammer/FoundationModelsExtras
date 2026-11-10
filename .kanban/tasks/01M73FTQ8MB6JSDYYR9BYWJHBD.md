---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73fysg1z4yrwesdpv7wggnz
  text: |-
    Research:
    - PooledEmbedder.swift is the model: a `ResidentHold<LoadedX>` and a private `LoadedX` struct that casts `hold.container`. The cast error drops the hold, so the pool evicts the model.
    - `DecisionLogitsSource.maximumPromptTokens` is a synchronous property. A model made from a ref has no container before its first call. `LogitsDecisionModel.check` reads the property only after the format tokenizes (thus after the load). Plan: give `ResidentHold` a synchronous read of the hold (`current`), and `maximumPromptTokens` gives the value of the container when the hold is there, and `nil` before the first call. The doc comment states this.
    - `ref` is a `public let ref: ModelRef` (a read-only public property; a settable `var` would not change the hold). For `init(hold:)` it is `hold.key.ref`.
    - Test support: `FixedLoader`, `RecordingLoader(name:log:loadsMayEnd:makeModel:)`, `Recorder`, `pool.waitForTheEarlierAdmissionJobs()`, `pool.isResident(_:)`.
  timestamp: 2026-11-10T19:46:28.993896+00:00
- actor: claude-code
  id: 01m73gdqz755qbbh3h7fk0jeqt
  text: |-
    ### implement — changed
    - evidence: 5 files. New: Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledLogitsModelTests.swift. Changed: Sources/FoundationModelsExtras/ModelPool/ResidentHold.swift (new `current`: a synchronous read of the hold, which starts no load), Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift (`FakeLogits`), docs/REFERENCE.md (section "Log probabilities: `PooledLogitsModel`"). RED: the build failed, `cannot find type 'PooledLogits'`. GREEN: `swift test --filter PooledLogitsModel` gives 15 tests in 1 suite, all pass. No compiler warning. The one build line `warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle` comes from SwiftPM for the MLX bundle, not from these files. No change to Package.swift.
    - notes: `maximumPromptTokens` does not load the model: `nil` before the first call of a model made from a ref, the container value after it. `ref` is `public let`. The doc example is mirrored in `readmeLogitsExample`.
    - next: /review
  timestamp: 2026-11-10T19:54:38.951246+00:00
position_column: doing
position_ordinal: '80'
title: PooledLogits protocol and PooledLogitsModel (a .llm hold as a log-probability source)
---
## What
FoundationModelsDecision reads typed decisions from the next-token log probabilities of a local model. Its consumer contract is `DecisionLogitsSource` in `../FoundationModelsDecision/Sources/FoundationModelsDecision/DecisionLogitsSource.swift`. Extras must give the same shape, so that the adapter in FoundationModelsDecisionPooled only passes the calls through. Extras must NOT depend on FoundationModelsDecision. The dependency goes Decision → Extras. Do not change `Package.swift`.

Create `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`. Use the same pattern as `PooledEmbedding` / `PooledEmbedder` in `Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift` (`ResidentHold`, a private `Loaded…` struct that casts `hold.container`).

- [ ] `public protocol PooledLogits: Sendable` with:
  - `var maximumPromptTokens: Int? { get }`: the largest prompt in tokens, or `nil` for no fixed limit.
  - `func tokenize(_ text: String) async throws -> [Int]`: no BOS, no EOS. Special-token text (for example `<|im_start|>`) becomes the special token, as Hugging Face `encode(text, add_special_tokens=False)` does.
  - `func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String?`: each message has the keys `role` and `content` only. The result is the chat template as text, with the generation prompt. `reasoning: false` turns thinking off. `nil` when the model has no template.
  - `func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]]`: the log probabilities under the FULL vocabulary distribution (log-softmax over all logits) of `candidates` at the last position of each prompt. The source evaluates each prompt exactly as given and adds no BOS. One row for each prompt, in order; one value for each candidate, in order.
  - Copy the doc comments of `DecisionLogitsSource`, in Simplified Technical English.
- [ ] `public struct PooledLogitsModel: PooledLogits` with `public init(ref: ModelRef, pool: ModelPool = .shared)` (loads nothing; the first call acquires a `ModelPoolKey(ref: ref, role: .llm)` hold one time only) and `public init(hold: ModelHold) throws`. It keeps the hold alive while a copy of the model exists, and forwards each call to the container. Give it `public var ref: ModelRef` so the adapter can report the model ID.
- [ ] `public enum PooledLogitsModelError: Error, Equatable, LocalizedError { case notLogitsCapable(ModelRef) }`. `init(hold:)`, and the first call of a model made from a ref, throw it when `hold.container` does not conform to `PooledLogits`.
- [ ] Docs: add a section "Log probabilities: `PooledLogitsModel`" to `docs/REFERENCE.md`, after "### An LLM by name as a `LanguageModel`: `PooledModel`".

## Acceptance Criteria
- [ ] A hold whose container conforms to `PooledLogits` gives a `PooledLogitsModel` that returns the values of the container for all four members.
- [ ] A hold whose container does not conform makes `init(hold:)` throw `PooledLogitsModelError.notLogitsCapable(ref)`; a model made from a ref throws the same error on its first call.
- [ ] Two first calls at the same time acquire the model one time only.
- [ ] When the last copy of the model goes away, the pool shows the hold as released.
- [ ] No new target, product or dependency. No new warnings.

## Tests
- [ ] Create `Tests/FoundationModelsExtrasTests/ModelPool/PooledLogitsModelTests.swift` (Swift Testing). Add a `FakeLogits: PooledLogits` stub to `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift` and use `FixedLoader` / `RecordingLoader`. Test: the forward of each member, the cast error from `init(hold:)` and from a ref, one acquire for concurrent first calls, and the release of the hold.
- [ ] Run `swift test --filter PooledLogitsModel`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision