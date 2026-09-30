---
depends_on:
- 01M3QMD6V09WGE7MJDV483VHBG
position_column: todo
position_ordinal: '8380'
title: IntegrationTests use the core MLXModelLoader; delete the test copy and the duplicate dependencies
---
## What
- Delete `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/MLXPooledLoader.swift` and change each use to `MLXModelLoader()` (or `ModelPool()` with the default loader). `IntegrationModels.acquire` uses `MLXModelLoader()` as its default.
- Delete `Support/MetalLibraryBootstrap.swift` if the core loader now makes the metal library available for `.xctest` bundles.
- `IntegrationTests/Package.swift`: remove the direct `mlx-swift-lm`, `swift-huggingface` and `swift-transformers` products that no test imports directly; keep only what a test file imports.

## Acceptance Criteria
- [ ] No MLX loader or metal-library code remains in `IntegrationTests/`.
- [ ] `IntegrationTests/Package.swift` names only the MLX products that a test imports.
- [ ] `swift test --package-path IntegrationTests` passes.

## Tests
- [ ] Existing `PooledEmbedderIntegrationTests`, `ModelPoolIntegrationTests`, `ToolHostingIntegrationTests` pass on the core loader.
- [ ] `swift test --package-path IntegrationTests` passes; `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool