---
comments:
- actor: claude-code
  id: 01m3r60y8b79dsjvzsz2ye7s5n
  text: |-
    ### finish — skipped
    - reason: the task contract `PooledModel.init(_ ref: ModelRef, pool:)` has an unlabeled first argument. The review of ^7e06vvc found that the rule swift/fluent-usage ("First argument should be labeled.") conflicts with the same contract. This task will get the same conflict.
    - next: a person must correct the rule or change the contract of ^7e06vvc and of this task. Then run /finish again.
  timestamp: 2026-09-30T03:34:09.419668+00:00
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: todo
position_ordinal: '8580'
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
- [ ] `PooledModel(ref: "…")` loads nothing.
- [ ] Two `session` calls (also from two `PooledModel` values with one name) make one load.
- [ ] Two sessions on one model never run `respond` at the same time.
- [ ] A fork continues the transcript of its parent.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`: with `ModelPool(loader:)` and a stub `LanguageModel`: lazy load, one load for two sessions, serialized responds, fork transcript, eviction.
- [ ] `IntegrationTests/.../PooledModelIntegrationTests.swift`: real `mlx-community/Qwen3-4B-4bit`: a session answers; `respond(generating:)` decodes a `@Generable` type; a fork remembers a fact from its parent.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool