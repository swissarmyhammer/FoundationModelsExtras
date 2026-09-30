---
position_column: todo
position_ordinal: '8180'
title: Built-in MLX loader in the core, measured footprint, load progress
---
## What
Give the Extras model pool its own MLX loader, so that a caller can load a model from a Hugging Face name with no loader and no byte count. This is the foundation of `PooledModel` and the name-based `PooledEmbedder`.

- `Package.swift`: add to the core `FoundationModelsExtras` target the products `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXFoundationModels`, `MLXHuggingFace` (package `https://github.com/swissarmyhammer/mlx-swift-lm`, branch `stable`), `HuggingFace` (`swift-huggingface` from 0.9.0) and `Tokenizers` (`swift-transformers` from 1.3.0). These are the pins of `IntegrationTests/Package.swift`.
- Remove each comment and test in Extras that forbids MLX in the core (manifest comments; any check in `Tests/FoundationModelsExtrasTests/CIWorkflowTests.swift` or other manifest tests).
- Move `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/MLXPooledLoader.swift` (and `MetalLibraryBootstrap.swift` if the core needs it) into `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift` as an internal built-in loader. An `.llm` key gives an `MLXLanguageModel` with capabilities `[.guidedGeneration, .toolCalling, .reasoning]` (the same as the Router, so one name always gives one model). An `.embedding` key gives the `MLXEmbedding` `PooledEmbedding`.
- Footprint: the loader measures the size of the downloaded weight files of the repository, and the pool counts that. Add `ModelPool.acquire(_ key: ModelPoolKey)` that uses the built-in loader and the measured footprint. Keep `acquire(_:footprintBytes:sessionBytes:loader:)` for a caller with its own loader.
- Progress: `ModelPool.progress(for: ModelRef) -> AsyncStream<ModelLoadProgress>` with `public enum ModelLoadProgress: Sendable { case downloading(fraction: Double), loading, ready, failed(String) }`. The download reports `downloading`.
- Change `IntegrationTests` to use the core loader, and delete its copy.

## Acceptance Criteria
- [ ] `import FoundationModelsExtras` gives `ModelPool.acquire(_ key:)` that loads `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` (`.embedding`) and `mlx-community/Qwen3-4B-4bit` (`.llm`) with no loader argument.
- [ ] A second `acquire` of the same key does not load again (one resident entry, two holds).
- [ ] `progress(for:)` gives `downloading`/`loading`/`ready` in order for a load, and `failed` for a bad repository name.
- [ ] No Extras source, manifest comment or test forbids MLX.
- [ ] `IntegrationTests` has no MLX loader of its own.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`: unit tests for `acquire(_ key:)` and `progress(for:)` with an injected test loader (internal seam), including one load for two holds and the `failed` case.
- [ ] `IntegrationTests/.../ModelPoolIntegrationTests.swift`: real load of both models by name; footprint > 0; second acquire adds a hold only.
- [ ] `swift test` at the root passes; `swift test --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool