---
comments:
- actor: claude-code
  id: 01m3rajhx5bmgscqna5r8hh2br
  text: |-
    Research:
    - The core `MetalLibraryBootstrap` uses `Bundle(for:)` on a class of the core module. The core is linked into the `.xctest` binary, thus it finds the `.xctest` bundle. The test copy is not necessary. I deleted it.
    - The core `MLXModelLoader` always gives an LLM the capabilities guided output, tool calls and reasoning. The test copy gave only guided output by default, and the tool capabilities only for `ToolSession`. `ToolSession` now uses the default loader.
    - `ModelMemory.weightBytes(of:)` stays. It is an independent measure of the weight files. `acquireByKeyLoadsEachModelByName` compares it with the footprint that `MLXModelLoader.footprintBytes(of:)` gives. If the test used the loader for both values, the check would compare a value with itself. Thus `HuggingFace` stays in `IntegrationTests/Package.swift`.
    - After the change, the test files import `MLXFoundationModels` (ModelPoolIntegrationTests), `HuggingFace` and `MLX` (ModelMemory). `MLX` comes through the `MLXFoundationModels` product, as before. The manifest removes `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXHuggingFace`, `Tokenizers` and the swift-transformers package.
  timestamp: 2026-09-30T04:53:40.901274+00:00
- actor: claude-code
  id: 01m3ravfe7nxvq0wavc7jezxd9
  text: |-
    ### implement — changed
    - evidence: deleted `Support/MLXPooledLoader.swift` and `Support/MetalLibraryBootstrap.swift`; changed `IntegrationTests/Package.swift`, `Support/IntegrationModels.swift`, `Support/RecordingLoader.swift`, `Support/ToolSession.swift`, `Support/ModelMemory.swift`, `PooledEmbedderIntegrationTests.swift`. The manifest now names `MLXFoundationModels`, `HuggingFace` and `ULID` (plus the two Extras products). It removes `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXHuggingFace`, `Tokenizers` and the swift-transformers package.
    - TDD: this card adds no production code. The existing integration tests are the check. Before the run, I deleted the old `mlx.metallib` link beside the test binary. The run made the link again, thus the core `MetalLibraryBootstrap` does the step for the `.xctest` bundle.
    - `swift test --package-path IntegrationTests`: 29 tests in 8 suites passed. `swift test`: 837 tests in 82 suites passed (4 known issues, by design in TelemetryCaptureTests).
    - Both builds show the SwiftPM warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS". The root package shows it too, thus this change did not cause it.
    - next: review
  timestamp: 2026-09-30T04:58:33.287980+00:00
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: doing
position_ordinal: '8180'
title: IntegrationTests use the core MLXModelLoader; delete the test copy and the duplicate dependencies
---
## What
- Delete `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/MLXPooledLoader.swift` and change each use to `MLXModelLoader()` (or `ModelPool()` with the default loader). `IntegrationModels.acquire` uses `MLXModelLoader()` as its default.
- Delete `Support/MetalLibraryBootstrap.swift` if the core loader now makes the metal library available for `.xctest` bundles.
- `IntegrationTests/Package.swift`: remove the direct `mlx-swift-lm`, `swift-huggingface` and `swift-transformers` products that no test imports directly; keep only what a test file imports.

## Acceptance Criteria
- [x] No MLX loader or metal-library code remains in `IntegrationTests/`.
- [x] `IntegrationTests/Package.swift` names only the MLX products that a test imports.
- [x] `swift test --package-path IntegrationTests` passes.

## Tests
- [x] Existing `PooledEmbedderIntegrationTests`, `ModelPoolIntegrationTests`, `ToolHostingIntegrationTests` pass on the core loader.
- [x] `swift test --package-path IntegrationTests` passes; `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool