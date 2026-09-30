---
comments:
- actor: claude-code
  id: 01m3r679sp2tzdndktt3e0e4bz
  text: |-
    Research done. Discoveries:
    - The contract `progress(for ref: ModelRef)` has a labeled first argument. Thus no conflict with the rule `swift/fluent-usage`.
    - The loader seam: `PooledModelLoader` gets a new requirement `load(key:progressHandler:)` with a default that reports `.loading` and then calls `load(_:)`. The first argument is labeled, for the rule `swift/fluent-usage`.
    - `MLXModelLoader` gets the download fraction from the `Downloader` of mlx-swift-lm (`download(id:revision:matching:useLatest:progressHandler:)`). A wrapper of `#hubDownloader()` reports `.downloading(fraction:)` for each `Progress`, and `.loading` when the download returns. `MLXLanguageModel` keeps a model cache for each process: a cache hit calls no loader closure and reports nothing. Thus the pool gives `loading` before `ready` when the loader did not report it.
    - The admission queue runs one load at a time. Each load has an id, so a late report of an old load has no effect.
    - The task says "Push to origin main". The caller of this step says: do not commit and do not push. The item "CI is green on the pushed commit" is thus for the commit step.
  timestamp: 2026-09-30T03:37:37.846797+00:00
- actor: claude-code
  id: 01m3r72qg9ft304mddr9yzafxt
  text: |-
    Implementation landed (TDD). RED: `swift build --build-tests` failed, because `ModelLoadProgress` and `ModelPool.progress(for:)` did not exist. GREEN: 19 of 19 new tests passed.

    Design:
    - `ModelLoadProgress.swift`: the public enum; `ModelLoadProgressBoard` (internal, in the state of the pool, under the state lock) keeps the live streams of each `ModelRef` and the load that runs now, with an id for each load; `ModelLoadProgressDelivery` sends the values after the state lock, under the publish lock, as the footprint streams do. The termination handler of a progress stream takes only the state lock. Thus the lock order of the pool does not change.
    - `PooledModelLoader.load(key:progressHandler:)`: a new requirement. The default reports `.loading`, then calls `load(_:)`. Thus each loader that exists still compiles.
    - `ModelPool.load` and `loadMeasured` run through `reportingProgress(of:_:)`: `ready` after `makeResident`, `failed(error.localizedDescription)` when the load or the measure throws. The pool drops a download after `loading`, each `ready` or `failed` that a loader reports, and each report of a load that ended. It gives `loading` before `ready` when the loader did not report it (an `MLXLanguageModel` cache hit calls no loader closure).
    - `ProgressReportingDownloader.swift`: wraps `#hubDownloader()`; `.downloading(fraction:)` for each `Progress`, `.loading` when the download returns. `MLXModelLoader` gives it to `loadModelContainer` and to `EmbedderModelFactory.loadContainer`.
    - `Package.swift`: the unit test target depends on `MLXLMCommon`, for the fake `Downloader` of the download tests.

    What did not work: `#expect(steps.allSatisfy(\.isFailure))` does not compile in the macro expansion ("call can throw, but it is not marked with 'try'"). `#expect(steps.map(\.isFailure) == [true])` replaced it.

    Open item for the commit step: the card says "Push to origin main" and "CI is green on the pushed commit". The caller of this step said: do not commit and do not push. Thus that acceptance item stays open.
  timestamp: 2026-09-30T03:52:36.617250+00:00
- actor: claude-code
  id: 01m3r72vs1c8z561fhknkdq2nk
  text: |-
    ### implement — changed
    - evidence: 11 files — new: Sources/FoundationModelsExtras/ModelPool/ModelLoadProgress.swift, Sources/FoundationModelsExtras/ModelPool/ProgressReportingDownloader.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift; changed: Sources/FoundationModelsExtras/ModelPool/{ModelPool.swift, ModelPoolKey.swift, MLXModelLoader.swift}, Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ModelPoolIntegrationTests.swift, Package.swift, README.md. `swift test`: 1464 tests pass (131+40+44+26+396+827), 0 failures, 4 known issues that TelemetryCaptureTests declares, 0 compiler warnings. `swift test --package-path IntegrationTests`: 26 tests pass. Each build shows only the known build-system line "missing creator for mutated node ... mlx-swift_Cmlx.bundle" (recorded on ^483vhbg).
    - next: review. The push to origin main and "CI is green on the pushed commit" stay open for the commit step.
  timestamp: 2026-09-30T03:52:40.993909+00:00
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: doing
position_ordinal: '8180'
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
- [x] A load gives `downloading`… (when it downloads), `loading`, `ready`, in that order, then the stream ends.
- [x] A bad repository name gives `failed`.
- [x] Two observers of one load see the same sequence.
- [ ] CI is green on the pushed commit.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift`: with `ModelPool(loader:)` and a test loader that reports progress: order, two observers, late observer, `failed`.
- [x] `IntegrationTests/.../ModelPoolIntegrationTests.swift`: a real load ends with `ready`.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool