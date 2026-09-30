---
depends_on: []
position_column: todo
position_ordinal: '8380'
title: PooledModel and PooledSession for an LLM by Hugging Face name
---
## What
Add `Sources/FoundationModelsExtras/ModelPool/PooledModel.swift` and `PooledSession.swift`:

```swift
let qwen = PooledModel("mlx-community/Qwen3-4B-4bit")                   // sync, loads nothing
let session = try await qwen.session(instructions: "…")                  // first call loads into the pool
let text = try await session.respond(to: "…")
let typed = try await session.respond(to: "…", generating: Selection.self)
let child = try await session.fork()
```

- `public struct PooledModel: Sendable { public init(_ ref: ModelRef, pool: ModelPool = .shared); public func session(instructions: String? = nil, tools: [any Tool] = []) async throws -> PooledSession }`.
- `session` does `pool.acquire(ModelPoolKey(ref:, role: .llm))` with the built-in loader. The pool loads each name one time only; each session adds a hold.
- `public final class PooledSession: Sendable`: `model: ModelRef`, `respond(to:) -> String`, `respond<T: Generable>(to:generating:) -> T`, `fork() -> PooledSession`. Inside: a `LanguageModelSession(model: <MLXLanguageModel of the hold>, instructions:, tools:)`.
- The session keeps its hold; `fork()` copies the transcript (and KV cache when MLX supports it) and keeps its own hold. The model is evicted after the last session goes.
- Each `respond` is one job on the `GenerationQueue` of the hold, so the calls to one model run one at a time.

## Acceptance Criteria
- [ ] `PooledModel("…")` is synchronous and loads nothing.
- [ ] Two `session` calls (also from two `PooledModel` values with one name) make one load.
- [ ] Two sessions on one model never run `respond` at the same time.
- [ ] A fork continues the transcript of its parent.
- [ ] The model is evicted after the last session (forks included) goes.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`: with an injected test loader and a stub `LanguageModel`: lazy load, one load for two sessions, serialized responds, eviction.
- [ ] `IntegrationTests/.../PooledModelIntegrationTests.swift`: real `mlx-community/Qwen3-4B-4bit` session answers a prompt; `respond(generating:)` decodes a `@Generable` type; a fork remembers a fact from its parent.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool