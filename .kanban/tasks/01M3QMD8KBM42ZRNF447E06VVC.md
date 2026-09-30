---
comments:
- actor: claude-code
  id: 01m3r4vf71p8dqnj58enbbfp11
  text: |-
    Research:
    - `PooledEmbedder` (Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift) is a struct with `init(hold:) throws`, `dimension`, and `embed(texts:)`. The `PooledEmbedding` protocol keeps `embed(texts:)` and `dimension`; only the method of `PooledEmbedder` changes to `embed(_:)`.
    - `ModelPool.acquire(_ key:)` loads with the loader of the pool, and the pool already makes one load for two concurrent acquires of one key (the second acquire finds the hold in its admission job). Thus the one-hold-for-each-embedder rule comes from a shared reference box in the embedder: one load task, which all concurrent first calls wait for.
    - `ModelPool.shared` exists (loader `MLXModelLoader()`). `ModelRef` is `ExpressibleByStringLiteral`.
    - Callers of `embed(texts:)` and `dimension` of `PooledEmbedder`: the unit tests in PooledEmbedderTests.swift, README.md, and in IntegrationTests: PooledEmbedderIntegrationTests.swift and ModelPoolSmokeTests.swift. Each changes with the rename and the removal of `dimension`. The integration tests that have a hold read the dimension from the container of the hold (`PooledEmbedding.dimension`).
    - Plan: a private final class box holds an enum state (unloaded / loading(task) / loaded). A failed load goes back to unloaded, so the next call tries again. A container that is not a `PooledEmbedding` gives `PooledEmbedderError.notAnEmbedding` from `embed(_:)`.
  timestamp: 2026-09-30T03:13:41.601672+00:00
- actor: claude-code
  id: 01m3r5dpc1mr6bg9c2v73qx5tp
  text: |-
    Implementation landed (TDD).
    - RED: the new PooledEmbedderTests did not compile, because `PooledEmbedder(_:pool:)` and `embed(_:)` did not exist.
    - GREEN: PooledEmbedderTests 15 of 15 pass.
    - Design: `PooledEmbedder` keeps a private final class `ResidentEmbedding`. Its state is an enum under a `Mutex`: `unloaded(source)`, `loading(source, Task)`, `loaded(LoadedEmbedding)`. The first call starts one load task, and all concurrent first calls wait for that task. After a failed load, the state goes back to `unloaded`, so the next call loads again. A container that is not a `PooledEmbedding` makes `embed(_:)` throw `notAnEmbedding`; the hold goes at once and the pool evicts the model. `init(hold:)` starts in the `loaded` state.
    - What did not work: `state.withLock(Self.access)` with a static function reference does not compile in Swift 6 ("sending" result conversion). A closure `{ Self.access(&$0) }` compiles.
    - Note: the pool already makes one load for two concurrent acquires of one key. Thus the unit test "two concurrent first embed calls make one load" would also pass with a naive embedder. The box is what gives one hold for each embedder.
    - `dimension` is gone from `PooledEmbedder`. The integration tests that have a hold now read the dimension from the container of the hold, with the new helper `IntegrationModels.embeddingDimension(of:)`. The similarity integration test now uses `PooledEmbedder(IntegrationModels.embedding.ref, pool: ModelPool())`, thus the core `MLXModelLoader`.
    - API break for callers outside this repo: `embed(texts:)` is now `embed(_:)`, and `dimension` is gone. The FoundationModelsRouter must change when it takes this version.
    - `RecordingLoader` (unit test support) got a `makeModel` parameter, so a test can give an embedding container through a recording loader.
    - Not done here, on the orchestrator order: commit, push, and the "CI is green on the pushed commit" item.
  timestamp: 2026-09-30T03:23:38.753756+00:00
- actor: claude-code
  id: 01m3r5dvffcnzz6rw3eyn573kj
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, README.md, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ModelPoolSmokeTests.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/IntegrationModels.swift. `swift test`: 813 tests in 80 suites pass (4 known issues from the existing withKnownIssue in TelemetryCaptureTests). `swift test --package-path IntegrationTests`: 24 tests in 7 suites pass. No compiler warnings; the only warning is the build-system line "missing creator for mutated node" of the mlx-swift_Cmlx bundle, which each build writes.
    - next: /review. The orchestrator commits and pushes; the CI acceptance item stays open until then.
  timestamp: 2026-09-30T03:23:43.983626+00:00
- actor: claude-code
  id: 01m3r606g1fb042zmhgmyk920s
  text: |-
    ### review — stuck
    - evidence: review sha HEAD~1..HEAD — 2 findings (2 confirmed, 0 refuted): Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift:40, Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift:64 (swift/fluent-usage). Both findings tell you to add a first argument label. The task contract tells you to use init(_ ref:pool:) and embed(_:). This is a true conflict. The acceptance criteria and the test list agree with the code.
    - next: a person must decide. Keep the contract and correct the swift/fluent-usage rule, or change the task contract to init(ref:pool:) and embed(texts:). The task stays in review.
  timestamp: 2026-09-30T03:33:45.089094+00:00
- actor: claude-code
  id: 01m3r60r6ksnz77789skvrr8aw
  text: |-
    ### finish iteration 1 — stuck
    - implement: changed — 7 files
    - test: green — swift test 813 pass; swift test --package-path IntegrationTests 24 pass
    - commit: 2ed83f5 (local, not pushed)
    - review: stuck — Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift:40, Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift:64 (swift/fluent-usage "First argument should be labeled." conflicts with the task contract init(_ ref:pool:) and embed(_:))
    - next: a person must correct the rule or change the task contract.
  timestamp: 2026-09-30T03:34:03.219418+00:00
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: review
position_ordinal: '80'
title: PooledEmbedder from a Hugging Face name
---
## What
`Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift`:

```swift
let embedder = PooledEmbedder(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")   // sync, loads nothing
let vectors = try await embedder.embed(texts: ["save my work"])                        // first call loads into the pool
let test = PooledEmbedder(ref: "any", pool: ModelPool(loader: fake))                 // tests
```

- `public init(ref: ModelRef, pool: ModelPool = .shared)`: synchronous, no load.
- `public func embed(texts: [String]) async throws -> [[Float]]`: the first call does `pool.acquire(ModelPoolKey(ref:, role: .embedding))` one time only, also for concurrent first calls. Each call is one job on the `GenerationQueue` of the hold.
- The hold is in a shared reference box: copies of one embedder share one hold; the hold goes with the last copy.
- `PooledEmbedder` has no `dimension` (it is not known before the load). The `PooledEmbedding` protocol keeps `dimension`.
- Keep `public init(hold:)` for a caller that acquires with its own sizing (the Router). Keep the name `embed(texts:)` for both inits (the `swift/fluent-usage` review rule wants labeled first arguments).
- `README.md`: the embedder example uses the name-based init; the example stays compiled by `PooledEmbedderTests`.
- Push to `origin main` when green.

## Acceptance Criteria
- [x] `PooledEmbedder(ref: "…")` loads nothing (the pool has no entry after init).
- [x] Two concurrent first `embed` calls make one load; two embedders with one name share one resident model.
- [x] The model is evicted after the last copy of the last embedder goes.
- [ ] CI is green on the pushed commit.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift`: with `ModelPool(loader:)` and a test loader: lazy load, one load for concurrent first calls, shared model, eviction.
- [x] `IntegrationTests/.../PooledEmbedderIntegrationTests.swift`: a real embed by name gives one vector for each text; a paraphrase has a higher cosine than an unrelated text.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool

## Review Findings (2026-09-29 21:27)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [ ] `Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift:40` `swift/fluent-usage` — First argument should be labeled. Per fluent-usage guidelines, omit the first argument label only for value-preserving conversions (e.g., `Int64(someUInt32)`). This initializer transforms a reference string into an embedder—not a value-preserving conversion—so the ref parameter must be labeled to form a clear grammatical phrase. Change the signature to `public init(ref: ModelRef, pool: ModelPool = .shared)` to include the label on the first argument and improve API fluency.
- [ ] `Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift:64` `swift/fluent-usage` — First argument should be labeled. Per fluent-usage guidelines, omit the first argument label only for value-preserving conversions (e.g., `Int64(someUInt32)`). The `embed` method performs computation, not a value-preserving conversion, so the texts parameter must be labeled to form a clear grammatical phrase at the call site. Change the signature to `public func embed(texts: [String]) async throws -> [[Float]]` to include the label and maintain API fluency and consistency with the PooledEmbedding protocol.

## Blocker: the rule and the task contract conflict (2026-09-29 21:27)

The two `swift/fluent-usage` findings above conflict with the written API contract of this task. A person must make a decision. Do not change the code before that decision.

- The task tells you to use `public init(ref: ModelRef, pool: ModelPool = .shared)`. The example `PooledEmbedder(ref: "mlx-community/...")` and the acceptance criterion `PooledEmbedder(ref: "…")` use no first label. The finding at `PooledEmbedder.swift:40` tells you to use `init(ref:pool:)`.
- The task tells you to rename `embed(texts:)` to `embed(_:)` for both inits. The example `embedder.embed(texts: ["save my work"])` uses no label. The finding at `PooledEmbedder.swift:64` tells you to use `embed(texts:)`. That is the name that the task removes.
- The commit 2ed83f5 is a breaking change for this rename. Callers, for example FoundationModelsRouter, must update to the new names.

Decision that is necessary (one of the two):

1. Keep the task contract. Then a person must correct the `swift/fluent-usage` rule, or write a rule that releases this API from it.
2. Obey the rule. Then a person must change the contract of this task (the What section, the example, and the acceptance criteria) to `init(ref:pool:)` and `embed(texts:)`, and change the dependent task ^zb8cxn (PooledModel and PooledSession) to match.

Check of the acceptance criteria and the test list against the code (HEAD 2ed83f5):

- "loads nothing": `PooledEmbedderTests` test "an embedder made from a name loads nothing". Present.
- "two concurrent first calls make one load" and "shared model": tests "two concurrent first embed calls of one embedder make one load" and "two embedders of one name share one resident model". Present.
- "evicted after the last copy": test "the model stays resident while a copy of an embedder exists, and is evicted after the last copy of the last embedder goes". Present.
- Integration test "a real embed by name gives one vector for each text, and a paraphrase has a higher cosine than an unrelated text". Present.
- README example is compiled by the test "the README example: an embedder from a name loads the model on its first call". Present.
- `PooledEmbedding` keeps `dimension` and `embed(texts:)`. `PooledEmbedder` has no `dimension`. `init(hold:)` stays. Present.
- The criterion "CI is green on the pushed commit" is for the orchestrator after the push. This review does not record it.