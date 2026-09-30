---
depends_on: []
position_column: todo
position_ordinal: '8280'
title: PooledEmbedder from a Hugging Face name
---
## What
Make `PooledEmbedder` (`Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift`) usable from a model name:

```swift
let embedder = PooledEmbedder("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")  // sync, loads nothing
let vectors = try await embedder.embed(["save my work"])                       // first call loads into the pool
```

- `public init(_ ref: ModelRef, pool: ModelPool = .shared)`: synchronous, no load.
- `public func embed(_ texts: [String]) async throws -> [[Float]]`: the first call does `pool.acquire(ModelPoolKey(ref:, role: .embedding))` (built-in loader) one time only, even for concurrent first calls. Each call is one job on the `GenerationQueue` of the hold.
- The hold is in a shared reference box: copies of one embedder share one hold, and the hold goes when the last copy goes.
- Remove the `dimension` property (the vectors carry their length).
- Keep `init(hold:)` only while the Router still uses it (`FoundationModelsRouter/Sources/FoundationModelsRouter/Resolution/PooledEmbeddingContainer.swift:21`). The Router task removes that use; delete `init(hold:)` in that task or when no caller remains.

## Acceptance Criteria
- [ ] `PooledEmbedder("…")` is synchronous and loads nothing (the pool has no entry after init).
- [ ] Two concurrent first `embed` calls make one load.
- [ ] Two embedders with the same name in one pool share one resident model.
- [ ] The model is evicted after the last copy of the last embedder goes.
- [ ] `PooledEmbedder` has no `dimension`.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift`: with an injected test loader: lazy load, one load for concurrent first calls, shared resident model, eviction after release.
- [ ] `IntegrationTests/.../PooledEmbedderIntegrationTests.swift`: real embed by name returns one vector per text, and similar texts have a higher cosine than unrelated texts.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool