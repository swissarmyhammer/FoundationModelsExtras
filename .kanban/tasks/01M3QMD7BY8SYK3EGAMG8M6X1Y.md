---
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: todo
position_ordinal: '8280'
title: Load progress stream on the model pool
---
## What
A caller can see the download and load of a model.

```swift
public enum ModelLoadProgress: Sendable, Equatable {
    case downloading(fraction: Double), loading, ready, failed(String)
}
extension ModelPool {
    public func progress(for ref: ModelRef) -> AsyncStream<ModelLoadProgress>
}
```

- `Sources/FoundationModelsExtras/ModelPool/ModelPool.swift` (and a new `ModelLoadProgress.swift`): the pool publishes the progress of each load of `ref`. A stream that starts after `ready` gives `ready` at once and ends.
- `MLXModelLoader` reports the download fraction from the Hugging Face downloader, then `loading`. The pool reports `ready` or `failed`.
- A `PooledModelLoader` that reports nothing still gives `loading` → `ready`/`failed`.
- `README.md`: document `progress(for:)`.
- Push to `origin main` when green.

## Acceptance Criteria
- [ ] A load gives `downloading`… (when it downloads), `loading`, `ready`, in that order, then the stream ends.
- [ ] A bad repository name gives `failed`.
- [ ] Two observers of one load see the same sequence.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift`: with `ModelPool(loader:)` and a test loader that reports progress: order, two observers, late observer, `failed`.
- [ ] `IntegrationTests/.../ModelPoolIntegrationTests.swift`: a real load ends with `ready`.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool