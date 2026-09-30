---
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: todo
position_ordinal: '8480'
title: PooledEmbedder from a Hugging Face name
---
## What
`Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift`:

```swift
let embedder = PooledEmbedder("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")   // sync, loads nothing
let vectors = try await embedder.embed(["save my work"])                        // first call loads into the pool
let test = PooledEmbedder("any", pool: ModelPool(loader: fake))                 // tests
```

- `public init(_ ref: ModelRef, pool: ModelPool = .shared)`: synchronous, no load.
- `public func embed(_ texts: [String]) async throws -> [[Float]]`: the first call does `pool.acquire(ModelPoolKey(ref:, role: .embedding))` one time only, also for concurrent first calls. Each call is one job on the `GenerationQueue` of the hold.
- The hold is in a shared reference box: copies of one embedder share one hold; the hold goes with the last copy.
- `PooledEmbedder` has no `dimension` (it is not known before the load). The `PooledEmbedding` protocol keeps `dimension`.
- Keep `public init(hold:)` for a caller that acquires with its own sizing (the Router). Rename `embed(texts:)` to `embed(_:)` for both inits.
- `README.md`: the embedder example uses the name-based init; the example stays compiled by `PooledEmbedderTests`.
- Push to `origin main` when green.

## Acceptance Criteria
- [ ] `PooledEmbedder("…")` loads nothing (the pool has no entry after init).
- [ ] Two concurrent first `embed` calls make one load; two embedders with one name share one resident model.
- [ ] The model is evicted after the last copy of the last embedder goes.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift`: with `ModelPool(loader:)` and a test loader: lazy load, one load for concurrent first calls, shared model, eviction.
- [ ] `IntegrationTests/.../PooledEmbedderIntegrationTests.swift`: a real embed by name gives one vector for each text; a paraphrase has a higher cosine than an unrelated text.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool