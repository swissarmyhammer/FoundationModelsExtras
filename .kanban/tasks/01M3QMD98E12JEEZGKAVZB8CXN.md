---
comments:
- actor: claude-code
  id: 01m3r60y8b79dsjvzsz2ye7s5n
  text: |-
    ### finish — skipped
    - reason: the task contract `PooledModel.init(_ ref: ModelRef, pool:)` has an unlabeled first argument. The review of ^7e06vvc found that the rule swift/fluent-usage ("First argument should be labeled.") conflicts with the same contract. This task will get the same conflict.
    - next: a person must correct the rule or change the contract of ^7e06vvc and of this task. Then run /finish again.
  timestamp: 2026-09-30T03:34:09.419668+00:00
- actor: claude-code
  id: 01m3r91wfg9frnq0q8jszaxf74
  text: |-
    Picked up. The description now has the labeled contract `PooledModel(ref:pool:)`, so the conflict of the last comment is gone.

    Research:
    - `ModelPool.acquire(_ key:)` does one load for each key: a resident key adds a hold at once, and a new key loads in the admission queue. Thus `session` can acquire one hold for each session, and two sessions make one load. No shared hold box is necessary for PooledModel.
    - `MLXModelLoader` gives an `MLXLanguageModel` for an `.llm` key. PooledSession casts the container to `any LanguageModel`, the same as PooledEmbedder casts to `PooledEmbedding`.
    - The SDK (macOS 27) has `LanguageModelSession(model: some LanguageModel, tools:, instructions: String?)` and `init(model:tools:transcript:)`. `LanguageModelSession` is `@unchecked Sendable`, `Transcript` and `Tool` are `Sendable`.
    - `Generable` is not `Sendable`, and `GenerationQueue.submit` needs a `Sendable` result. Thus the typed respond runs `respond(to:schema:)` in the job and makes `T` from the `GeneratedContent` after the job.
    - A test `LanguageModel` needs an executor (`LanguageModelExecutor`) whose `Configuration` is `Hashable`. `FoundationModelsAgents/Tests/.../ScriptedAgentModel.swift` shows the shape: the identity of a script class is the configuration.
    - The fork reads the transcript of the parent as one job in the queue, so it does not read the transcript while a respond runs. It then acquires its own hold (the model is resident, so no load).
  timestamp: 2026-09-30T04:27:06.096596+00:00
- actor: claude-code
  id: 01m3r9wygqyd52w6ae3syjnmfa
  text: |-
    Implementation landed (TDD).

    - `PooledModel(ref:pool:)` keeps the pool and an `.llm` key, and loads nothing. `session(instructions:tools:)` calls `pool.acquire(key)` and makes a `PooledSession` with that hold.
    - `PooledSession` casts the container to `any LanguageModel` (else `PooledSessionError.notALanguageModel(key:containerType:)`, and the hold goes, so the model is evicted). Each `respond` is one job on `hold.queue`. `respond(to:generating:)` runs `respond(to:schema:)` in the job and makes `T` from the `GeneratedContent` after the job, because `Generable` is not `Sendable`. `fork()` reads the transcript as one queue job, then acquires its own hold (`pool.acquire(key)` on a resident key gives a hold at once), and makes a session from `LanguageModelSession(model:tools:transcript:)` with the same tools.
    - Test stub: `Tests/.../ModelPool/StubLanguageModel.swift`, a FoundationModels `LanguageModel` with an executor. It answers with the prompts of the transcript joined with a space, so a fork test sees the prompts of the parent. An answer of JSON text decodes for guided generation.
    - A mutation check: with the queue removed from `respond`, the FIFO test failed (the second call did not wait in the queue). The queue was put back.
    - To remove a copied helper, `waitForQueuedCalls` of PooledEmbedderTests and of PooledModelTests is now one `GenerationQueue.waitForWaitingJobs(count:)` in `ModelPoolTestSupport.swift`. The literals 1 and 2 at the changed call sites are now named constants.
    - Integration: `PooledModelIntegrationTests.swift` uses `IntegrationModels.toolCallingLLM` (`mlx-community/Qwen3-4B-4bit`) through `ModelPool()` with `MLXModelLoader`. The three tests passed (about 3 s, 3 s and 5 s).
    - Not done here, as the orchestrator said: commit, push, and the CI check of the pushed commit (the last acceptance item stays open).
  timestamp: 2026-09-30T04:41:52.919781+00:00
- actor: claude-code
  id: 01m3r9x3mj2gg4jre4b66nxcqj
  text: |-
    ### implement — changed
    - evidence: 9 files. New: Sources/FoundationModelsExtras/ModelPool/PooledModel.swift, Sources/FoundationModelsExtras/ModelPool/PooledSession.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift (10 tests), Tests/FoundationModelsExtrasTests/ModelPool/StubLanguageModel.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledModelIntegrationTests.swift (3 tests). Changed: README.md, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift, plus this card. `swift test`: 837 tests in 82 suites passed (4 known issues of TelemetryCaptureTests, which existed before), 0 warnings. `swift test --package-path IntegrationTests`: 29 tests in 8 suites passed.
    - next: /review. Commit, push and the CI check are for the orchestrator. The task stays in doing.
  timestamp: 2026-09-30T04:41:58.162896+00:00
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: doing
position_ordinal: '8180'
title: PooledModel and PooledSession for an LLM by Hugging Face name
---
## What
New `Sources/FoundationModelsExtras/ModelPool/PooledModel.swift` and `PooledSession.swift`:

```swift
let qwen = PooledModel(ref: "mlx-community/Qwen3-4B-4bit")                   // sync, loads nothing
let session = try await qwen.session(instructions: "…")                  // first call loads into the pool
let text = try await session.respond(to: "…")
let typed = try await session.respond(to: "…", generating: Answer.self)
let child = try await session.fork()
let test = PooledModel(ref: "any", pool: ModelPool(loader: fake))             // tests
```

- `public struct PooledModel: Sendable { init(ref: ModelRef, pool: ModelPool = .shared); func session(instructions: String? = nil, tools: [any Tool] = []) async throws -> PooledSession }`. `session` does `pool.acquire(ModelPoolKey(ref:, role: .llm))`: one load for each name in a pool, one hold for each session.
- `public final class PooledSession: Sendable`: `model: ModelRef`, `respond(to:) -> String`, `respond<T: Generable>(to:generating:) -> T`, `fork() -> PooledSession`. Inside: `LanguageModelSession(model: <the MLXLanguageModel of the hold>, instructions:, tools:)`.
- The session keeps its hold; `fork()` continues the transcript and keeps its own hold. The model is evicted after the last session (forks included) goes.
- Each `respond` is one job on the `GenerationQueue` of the hold: calls to one model run one at a time.
- A test loader can return any FoundationModels `LanguageModel` for `.llm`, so another package can test with a stub model.
- `README.md`: document `PooledModel` and `PooledSession`.
- Push to `origin main` when green.

## Acceptance Criteria
- [x] `PooledModel(ref: "…")` loads nothing.
- [x] Two `session` calls (also from two `PooledModel` values with one name) make one load.
- [x] Two sessions on one model never run `respond` at the same time.
- [x] A fork continues the transcript of its parent.
- [ ] CI is green on the pushed commit.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`: with `ModelPool(loader:)` and a stub `LanguageModel`: lazy load, one load for two sessions, serialized responds, fork transcript, eviction.
- [x] `IntegrationTests/.../PooledModelIntegrationTests.swift`: real `mlx-community/Qwen3-4B-4bit`: a session answers; `respond(generating:)` decodes a `@Generable` type; a fork remembers a fact from its parent.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool