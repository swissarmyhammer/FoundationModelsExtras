---
comments:
- actor: claude-code
  id: 01m3qmpgxrkav2c10esmgevfvk
  text: |-
    Research done.
    - The copy to move is `IntegrationTests/.../Support/MLXPooledLoader.swift` (with `MLXEmbedding`) and `Support/MetalLibraryBootstrap.swift`. `ModelMemory.weightBytes(of:)` in the same folder already measures the weight files (`*.safetensors`) of a key in `HubCache.default`. The new footprint measure uses the same method.
    - `PooledModelLoader` has only `load` and `evict`. A fake loader must give the footprint of `acquire(_ key:)`, thus the protocol gets a third requirement `footprintBytes(of:)`, with a default of 0 in an extension, so that each conformer in other packages still compiles.
    - MLX finds its metal library beside the binary (`mlx.metallib`), or in `mlx-swift_Cmlx.bundle` of the main bundle. A plain executable finds the bundle itself. A `.xctest` binary is in `<X>.xctest/Contents/MacOS`, and needs a link.
    - Text that forbids MLX in the core: the comment in `IntegrationTests/Package.swift`, `README.md` ("only that package depends on MLX"), `plan.md` §5 and the ModelPool note ("MLX stays out of this package"). `CIWorkflowTests.swift` pins CI lines only; it does not forbid MLX.
    - Task ^?  "IntegrationTests use the core MLXModelLoader" (01M3QMD7X7V79G3VFHDZQGV689) deletes the test copy later. This task keeps the test copy.
  timestamp: 2026-09-29T22:31:22.296053+00:00
- actor: claude-code
  id: 01m3qz8cf31n386ydvc4r9d3vb
  text: |-
    Implementation landed in the core (second agent, continued from the partial edits).
    - Kept the partial edits: Package.swift MLX dependencies, RecordingLoader measure, and the ModelPoolTests for acquire by key. RED: `swift build --build-tests` failed on the missing `ModelPool(loader:)`, `acquire(_:)`, `loader` and `MLXModelLoader` (the first build with MLX took about 3 minutes).
    - `PooledModelLoader.footprintBytes(of:)` is a requirement with a default of 0. `ModelPool.acquire(_:)` and `ModelPoolAdmission.acquire(_:)` load with the loader of the pool, then measure. When the measure fails, the loader evicts the container and the error goes to the caller.
    - New files: `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift` (with `MLXModelLoaderError` and the private `MLXEmbedding`), `MetalLibraryBootstrap.swift`. The measure resolves a ref file, or uses the revision as a commit, and throws `notInCache` when no snapshot is there.
    - New unit tests: `MLXModelLoaderTests` (a small HubCache in a temporary directory; the metal library link beside the xctest binary). The test target now names the `HuggingFace` product.
    - `swift test --filter 'ModelPoolTests|MLXModelLoaderTests'`: 25 tests pass. The build shows one build-system line for the MLX bundle: "warning: missing creator for mutated node: ... mlx-swift_Cmlx.bundle/Contents/MacOS". It comes from the mlx-swift resource bundle, not from Extras code.
  timestamp: 2026-09-30T01:35:53.315468+00:00
- actor: claude-code
  id: 01m3r11th7zyh19z3z849w0v5j
  text: |-
    All card items are in the working tree. One test gap stays open.
    - The metal library step now has `linkIfMissing(binaryDirectory:bundleParentDirectory:)`. Two unit tests build a fake `.xctest` layout in a temporary directory. RED: the build failed on the missing function. GREEN: 5 of 5 `MLXModelLoaderTests` pass. The old test that read the real test binary depended on the build layout of CI, so it was replaced.
    - README: new section "Load by name: MLXModelLoader"; the "only that package depends on MLX" text is removed. `IntegrationTests/Package.swift` comment and `plan.md` §5 no longer forbid MLX in the core; plan.md records the decision of 2026-09-29.
    - New integration test `acquireByKeyLoadsEachModelByName` (arguments: the embedding model and `mlx-community/Qwen3-4B-4bit`) loads through `ModelPool()` with no loader: one entry, one resident model, footprint > 0 and equal to the weight files. It passed in each run.
    - `swift test`: 804 tests pass (4 known issues are the intentional `withKnownIssue` of `TelemetryCaptureTests`).
    - Gap: `swift test --package-path IntegrationTests` passed 1 time in 3 full runs. The failing test is the existing `concurrentAcquiresLoadTheModelOneTime` memory check ("MLX active memory grew 312732056 bytes; one model is 695283921 bytes"). A filtered loop gave 3 failures in 10 runs with this change, and 0 failures in 5 runs on HEAD (git stash). The cause is not known. All data is on the new task ^8erseht.
    - The test copy `MLXPooledLoader.swift` stays in IntegrationTests; task ^zqgv689 deletes it.
    - ARCHITECTURE.md does not exist.
  timestamp: 2026-09-30T02:07:15.495503+00:00
- actor: claude-code
  id: 01m3r120127g049dqcp4v75hwb
  text: |-
    ### implement — stuck
    - evidence: 14 files — Package.swift, README.md, plan.md, IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ModelPoolIntegrationTests.swift, Sources/FoundationModelsExtras/ModelPool/{ModelPool.swift, ModelPoolKey.swift, MLXModelLoader.swift (new), MetalLibraryBootstrap.swift (new)}, Tests/FoundationModelsExtrasTests/ModelPool/{ModelPoolTests.swift, ModelPoolTestSupport.swift, MLXModelLoaderTests.swift (new)}. `swift test`: 804 pass. `swift test --package-path IntegrationTests`: 23 tests, passed 1 of 3 full runs; the existing memory check `concurrentAcquiresLoadTheModelOneTime` fails some of the time (3 of 10 filtered runs with this change, 0 of 5 on HEAD).
    - next: a person decides whether ^8erseht (the flaky memory check) blocks this card, or whether this card goes to review with ^8erseht open. The card item "swift test --package-path IntegrationTests pass" is not reliably met. The push step of the card was not done, by order of the orchestrator.
  timestamp: 2026-09-30T02:07:21.122088+00:00
- actor: claude-code
  id: 01m3r124pdt5mys4kw8nm92wqj
  text: 'Correction to the step record: the file count is 12, not 14. The list of files in the record is correct.'
  timestamp: 2026-09-30T02:07:25.901955+00:00
- actor: claude-code
  id: 01m3r12x13j38qjjwh9vgch9md
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 12 files changed, not committed. swift test: 804 pass. swift test --package-path IntegrationTests: 1 of 3 full runs pass.
    - cause: the existing test concurrentAcquiresLoadTheModelOneTime fails some of the time after GenerationQueueIntegrationTests (3/10 runs with the change, 0/5 on HEAD). Data is on ^8erseht.
    - test: not run. commit: not run. review: not run. push: not done.
    - next: a person must decide if ^8erseht blocks this task. The uncommitted changes stay in the working tree.
  timestamp: 2026-09-30T02:07:50.819835+00:00
- actor: claude-code
  id: 01m3r3p56h8radd2g555hwbpq5
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (b22ba99): 0 findings, 0 confirmed, 0 refuted; 14 of 14 validator runs completed, 0 failed. The engine reviewed 16 files. It did not review `.kanban/` (ignore rule), `README.md` and `plan.md` (no validator matches these files).
    - acceptance check: `public struct MLXModelLoader`, `public static let shared = ModelPool()`, `public init(loader: any PooledModelLoader = MLXModelLoader())`, `public func acquire(_ key: ModelPoolKey)` and `footprintBytes(of:)` (with a default of 0) are in `Sources/FoundationModelsExtras/ModelPool/`. `Package.swift` has the MLX, `HuggingFace` and `Tokenizers` products in the core target. No Extras source, comment, test or README line forbids MLX.
    - test check: `ModelPoolTests` has tests for one load with two holds, eviction after the last release, the measured footprint, and a failed measure. `ModelPoolIntegrationTests.acquireByKeyLoadsEachModelByName` loads both models by name through `ModelPool()` and checks that the footprint is more than 0.
    - note: the comment "finish iteration 1 — stuck" is out of date. ^8erseht (done) fixed the flaky memory check, and the tree is green.
    - not in scope: the push and CI items. The orchestrator pushes after the task is done.
    - next: the task is in `done`.
  timestamp: 2026-09-30T02:53:18.929829+00:00
- actor: claude-code
  id: 01m3r3pg41swqx4xv2pm83ky7k
  text: |-
    ### finish iteration 2 — clean
    - implement: done in iteration 1; ^8erseht fixed the flaky memory check
    - test: green — swift test 804 pass; swift test --package-path IntegrationTests 24 pass
    - commit: b22ba99
    - review: clean — 0 findings
    - push: origin main (the user approved the push)
  timestamp: 2026-09-30T02:53:30.113230+00:00
position_column: done
position_ordinal: d880
title: 'Built-in MLX loader in the core: MLXModelLoader, ModelPool(loader:), acquire by key'
---
## What
Give the model pool its own public MLX loader, so a caller can load a model from a Hugging Face name with no loader and no byte count, and a test in any package can inject a fake loader.

```swift
public struct MLXModelLoader: PooledModelLoader { public init() }   // .llm -> MLXLanguageModel, .embedding -> PooledEmbedding
public final class ModelPool {
    public static let shared = ModelPool()                             // uses MLXModelLoader()
    public init(loader: any PooledModelLoader = MLXModelLoader())
    public func acquire(_ key: ModelPoolKey) async throws -> ModelHold // pool loader + measured footprint
    // acquire(_:footprintBytes:sessionBytes:loader:) stays (the Router keeps its own sizing)
}
```

- `Package.swift`: add to the core target `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXFoundationModels`, `MLXHuggingFace` (`https://github.com/swissarmyhammer/mlx-swift-lm`, branch `stable`), `HuggingFace` (`swift-huggingface` from 0.9.0), `Tokenizers` (`swift-transformers` from 1.3.0).
- Remove each comment and test in Extras that forbids MLX in the core (manifest comments, `Tests/FoundationModelsExtrasTests/CIWorkflowTests.swift` and any other manifest check).
- New `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`: the code of `IntegrationTests/.../Support/MLXPooledLoader.swift` (with `MLXEmbedding`). `.llm` gives an `MLXLanguageModel` with `[.guidedGeneration, .toolCalling, .reasoning]`. `.embedding` gives a `PooledEmbedding` (the protocol keeps `dimension`: a loaded container knows it).
- Metal library: the loader makes the MLX metal library available for a `.xctest` bundle and for a SwiftPM executable (`swift run`), one time for each process.
- Footprint: `acquire(_ key:)` measures the size of the downloaded weight files of the repository and counts that.
- `README.md`: remove "only that package depends on MLX"; document `MLXModelLoader`, `ModelPool(loader:)` and `acquire(_ key:)`.
- Push to `origin main` when green.

## Acceptance Criteria
- [ ] `ModelPool.shared.acquire(ModelPoolKey(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", role: .embedding))` and the same for `mlx-community/Qwen3-4B-4bit` (`.llm`) load with no loader argument.
- [ ] A second acquire of one key does not load again (one resident entry, two holds).
- [ ] `ModelPool(loader: fake)` uses the fake loader for `acquire(_ key:)`; a test in another package can do this (all of it is public).
- [ ] No Extras source, comment, test or README line forbids MLX.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`: `ModelPool(loader: RecordingLoader())` + `acquire(_ key:)`: one load for two holds, eviction after the last release, footprint counted.
- [ ] `IntegrationTests/.../ModelPoolIntegrationTests.swift`: real load of both models by name through `ModelPool()`; footprint > 0.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool