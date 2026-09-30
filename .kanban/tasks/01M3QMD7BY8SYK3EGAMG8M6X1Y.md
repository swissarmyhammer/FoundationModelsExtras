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
- actor: claude-code
  id: 01m3r7jsty1k4xayevhyft0tg7
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (fb012ca). 2 findings: Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift:203, Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift:214 (code-hygiene/magic-numbers-swift). The acceptance criteria and the test list agree with the code.
    - next: Replace the magic numbers with named constants in the two test files. Remove the cause from all of each file. Then review again.
  timestamp: 2026-09-30T04:01:23.294286+00:00
- actor: claude-code
  id: 01m3r7k6000gnajdx5err56cgb
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files
    - test: green — swift test 827 pass (81 suites); swift test --package-path IntegrationTests 26 pass
    - commit: fb012ca
    - review: findings — Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift:203, Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift:214 (code-hygiene/magic-numbers-swift)
  timestamp: 2026-09-30T04:01:35.744300+00:00
- actor: claude-code
  id: 01m3r7rkpsyp2393d1eapfg1p2
  text: |-
    Review findings worked (code-hygiene/magic-numbers-swift). I removed the cause from all of each file, and from the other Swift files of this task.
    - MLXModelLoaderTests.swift: `StepDownloader.completedUnits` was `[1, 3, 4]`. It is now `[1, partialUnits, totalUnits]`, with the new constant `partialUnits: Int64 = 3`. The last report completes the download, thus it uses `totalUnits`.
    - ModelLoadProgressTests.swift: new constants `ReportingLoader.firstDownloadFraction = 0.25` and `secondDownloadFraction = 0.75` for the default reports. New constant `droppedDownloadFraction = 0.5` for the two tests that report a download that the pool must drop (it was a literal in two places; swiftlint did not report those, but they were magic numbers).
    - Check: swiftlint `no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]` (the config of the rule) on each Swift file of commit fb012ca: 0 findings (before: 4, on the two lines of the findings). A search of the added lines of the diff finds each numeric literal other than 0 and 1 only in a named `static let`.
    - Discovery: the `files` edit with `replace_all: true` replaced only 1 of 2 matches of `.downloading(fraction: 0.5)`. I edited the second match by hand. Check the replacement count after each `replace_all`.
  timestamp: 2026-09-30T04:04:33.625129+00:00
- actor: claude-code
  id: 01m3r7rpc5ehffqks6qtb413k4
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift. `swift test`: 827 tests in 81 suites pass, 0 failures, 4 known issues (TelemetryCaptureTests declares them), 0 compiler warnings. The only build line is the known "missing creator for mutated node ... mlx-swift_Cmlx.bundle". swiftlint no_magic_numbers on the changed Swift files: 0 findings. 2 of 2 review findings are checked.
    - next: review. The push to origin main and "CI is green on the pushed commit" stay open for the commit step.
  timestamp: 2026-09-30T04:04:36.357832+00:00
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

## Review Findings (2026-09-29 21:56)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 7 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift:203` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/ModelLoadProgressTests.swift:214` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
