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
- actor: claude-code
  id: 01m73grc4s7qxpfqs4e0d044x9
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (a346284); 2 findings, 2 confirmed, 0 refuted — Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift:156, Tests/FoundationModelsExtrasTests/ModelPool/PooledLogitsModelTests.swift:176. `swift test --filter PooledLogitsModel`: 15 tests pass. The reviewer ticked all 11 subtask boxes; the commit satisfies each one.
    - next: Correct the 2 open items in "Review Findings (2026-11-10 13:57)". Then run the review again.
  timestamp: 2026-11-10T20:00:27.289635+00:00
- actor: claude-code
  id: 01m73gryenq4arxz8xv29sxhfa
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files
    - test: green — swift test, 1804 + 13 passed, 0 failed
    - commit: a346284
    - review: findings — Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift:156, Tests/FoundationModelsExtrasTests/ModelPool/PooledLogitsModelTests.swift:176
  timestamp: 2026-11-10T20:00:46.037280+00:00
- actor: claude-code
  id: 01m73gz657khx2vbqcq4hrcpbg
  text: |-
    Review findings worked.
    1. dead-code-swift, `LoadedLogits.hold` assign-only: `LoadedLogits.init(hold:)` no longer takes a `ref` parameter. It reads the ref for `notLogitsCapable` from `hold.key.ref`. `PooledLogitsModel.init(hold:)` makes the `LoadedLogits` first and sets `ref = loaded.hold.key.ref`, thus the stored hold is read. The hold stays stored, so the model stays resident while a copy exists. `periphery scan --retain-public --skip-build` gives no finding for PooledLogits.swift now. Note: `LoadedEmbedding.hold` in PooledEmbedder.swift has the same shape, but that file is not in the scope of this card.
    2. no-test-cheating: `aNamedModelThatIsNotLogitsCapableKeepsNoHold` now uses `await #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.key.ref))` and keeps the `isResident` check after it. No other `try?` is in the test file.
  timestamp: 2026-11-10T20:04:10.535112+00:00
- actor: claude-code
  id: 01m73gz7jy7txvpefv6ctcyqdp
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledLogitsModelTests.swift; `swift test --filter PooledLogitsModel` — 15 tests in 1 suite passed, 0 failures, 0 warnings
    - next: test, then review
  timestamp: 2026-11-10T20:04:11.998382+00:00
- actor: claude-code
  id: 01m73h4smva3d7jj0tzz5yjrsf
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (41f5dbf); 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. The 2 items of the 2026-11-10 13:57 section are checked.
    - next: none. The task moved to done.
  timestamp: 2026-11-10T20:07:14.331095+00:00
- actor: claude-code
  id: 01m73h55kasehrhsmq6ytzmxf6
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 2 files
    - test: green — swift test, 1804 + 13 passed, 0 failed
    - commit: 41f5dbf
    - review: clean — 0 findings
  timestamp: 2026-11-10T20:07:26.570205+00:00
position_column: done
position_ordinal: ffde80
title: PooledLogits protocol and PooledLogitsModel (a .llm hold as a log-probability source)
---
## What
FoundationModelsDecision reads typed decisions from the next-token log probabilities of a local model. Its consumer contract is `DecisionLogitsSource` in `../FoundationModelsDecision/Sources/FoundationModelsDecision/DecisionLogitsSource.swift`. Extras must give the same shape, so that the adapter in FoundationModelsDecisionPooled only passes the calls through. Extras must NOT depend on FoundationModelsDecision. The dependency goes Decision → Extras. Do not change `Package.swift`.

Create `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift`. Use the same pattern as `PooledEmbedding` / `PooledEmbedder` in `Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift` (`ResidentHold`, a private `Loaded…` struct that casts `hold.container`).

- [x] `public protocol PooledLogits: Sendable` with:
  - `var maximumPromptTokens: Int? { get }`: the largest prompt in tokens, or `nil` for no fixed limit.
  - `func tokenize(_ text: String) async throws -> [Int]`: no BOS, no EOS. Special-token text (for example `<|im_start|>`) becomes the special token, as Hugging Face `encode(text, add_special_tokens=False)` does.
  - `func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String?`: each message has the keys `role` and `content` only. The result is the chat template as text, with the generation prompt. `reasoning: false` turns thinking off. `nil` when the model has no template.
  - `func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]]`: the log probabilities under the FULL vocabulary distribution (log-softmax over all logits) of `candidates` at the last position of each prompt. The source evaluates each prompt exactly as given and adds no BOS. One row for each prompt, in order; one value for each candidate, in order.
  - Copy the doc comments of `DecisionLogitsSource`, in Simplified Technical English.
- [x] `public struct PooledLogitsModel: PooledLogits` with `public init(ref: ModelRef, pool: ModelPool = .shared)` (loads nothing; the first call acquires a `ModelPoolKey(ref: ref, role: .llm)` hold one time only) and `public init(hold: ModelHold) throws`. It keeps the hold alive while a copy of the model exists, and forwards each call to the container. Give it `public var ref: ModelRef` so the adapter can report the model ID.
- [x] `public enum PooledLogitsModelError: Error, Equatable, LocalizedError { case notLogitsCapable(ModelRef) }`. `init(hold:)`, and the first call of a model made from a ref, throw it when `hold.container` does not conform to `PooledLogits`.
- [x] Docs: add a section "Log probabilities: `PooledLogitsModel`" to `docs/REFERENCE.md`, after "### An LLM by name as a `LanguageModel`: `PooledModel`".

## Acceptance Criteria
- [x] A hold whose container conforms to `PooledLogits` gives a `PooledLogitsModel` that returns the values of the container for all four members.
- [x] A hold whose container does not conform makes `init(hold:)` throw `PooledLogitsModelError.notLogitsCapable(ref)`; a model made from a ref throws the same error on its first call.
- [x] Two first calls at the same time acquire the model one time only.
- [x] When the last copy of the model goes away, the pool shows the hold as released.
- [x] No new target, product or dependency. No new warnings.

## Tests
- [x] Create `Tests/FoundationModelsExtrasTests/ModelPool/PooledLogitsModelTests.swift` (Swift Testing). Add a `FakeLogits: PooledLogits` stub to `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift` and use `FixedLoader` / `RecordingLoader`. Test: the forward of each member, the cast error from `init(hold:)` and from a ref, one acquire for concurrent first calls, and the release of the hold.
- [x] Run `swift test --filter PooledLogitsModel`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision

## Review Findings (2026-11-10 13:57)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 13 not reviewed.

> 12 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 12 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `docs/REFERENCE.md` — no validator matches this file

- [x] `Sources/FoundationModelsExtras/ModelPool/PooledLogits.swift:156` `code-hygiene/dead-code-swift` — var.instance `hold` is assignOnlyProperty.
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/PooledLogitsModelTests.swift:176` `test-integrity/no-test-cheating` — The test discards the error of `model.tokenize("a")` with `try?`. The test name says the model must keep no hold when the container is not a PooledLogits, but the test never checks that the call threw `notLogitsCapable`. If the call failed for another reason, the test would still pass. The failure is swallowed instead of proven. Replace `_ = try? await model.tokenize("a")` with `await #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.key.ref)) { try await model.tokenize("a") }`, then keep the `pool.isResident` check after it.
