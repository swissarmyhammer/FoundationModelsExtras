---
assignees:
- claude-code
depends_on:
- 01M4NXZS41BMJKF4Z96556W4RS
position_column: todo
position_ordinal: '8980'
title: 'Model load telemetry: a span with phases and a load timer for MLXModelLoader'
---
## What

A model load can take minutes (a download, then the weights), but it has no span and no metric. A load that hangs shows nothing.

This task covers the load span, the load phases, the load timer and the footprint recorder. The `prewarm` log record and the evict timer are in task `kaghnvn`.

Files and points:
- `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`: `load(key:progressHandler:)` (`:91`), `footprintBytes(of:)` (`:125`). The phases: the Metal library install (`MetalLibraryBootstrap.install()`, `:94`); the download (through `ProgressReportingDownloader`, `:96`); the weights load (`loadModelContainer` in `loadLanguageModel`, `:180-191`, and `EmbedderModelFactory.shared.loadContainer` in `MLXEmbedding.load`, `:232-238`); and `model.preload()` (`:192`, LLM only).
- `Sources/FoundationModelsExtras/ModelPool/ModelPool.swift`: `load(_:footprintBytes:sessionBytes:loader:)` (`:210`) and `loadMeasured(_:)` (`:230`) call the loader.

Approach (each name in `ExtrasTelemetry.swift`, metric objects made at call time):
- Span `FoundationModelsExtras.model.load` through `TracedCall`, so that a hung load has an "enter" record. Open it in the pool (`load`/`loadMeasured`), so that each loader gets it. Attributes: `model.ref`, `model.revision`, `model.role` (`llm` or `embedding`).
- Child spans in `MLXModelLoader` for the Metal library install (`FoundationModelsExtras.model.load.metal_install`), the download (`FoundationModelsExtras.model.load.download`, attribute `download.bytes`, from the completed bytes that the progress handler gets), the weights load (`FoundationModelsExtras.model.load.weights`), and `preload()` (`FoundationModelsExtras.model.load.preload`).
- Timer `FoundationModelsExtras.model.load.duration` with `model.ref`, `model.role` and the outcome (`succeeded` or `failed`).
- Recorder `FoundationModelsExtras.model.footprint.bytes` with `model.ref` and `model.role`, from `footprintBytes(of:)` or the measured bytes in `loadMeasured`.
- Never record a file path, a cache folder, a URL or `error.localizedDescription`.

## Acceptance Criteria
- [ ] Each pool load opens one `FoundationModelsExtras.model.load` span with `model.ref`, `model.revision` and `model.role`, and writes one "enter" log record.
- [ ] `MLXModelLoader` opens a child span for each phase that runs (Metal install, download, weights load, and `preload()` for an LLM).
- [ ] Each load records one duration on `FoundationModelsExtras.model.load.duration` with the outcome. Each measured load records `FoundationModelsExtras.model.footprint.bytes`.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`: with a fake loader from `ModelPoolTestSupport.swift`, `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test the load span, the attributes, the load timer for a load that succeeds and a load that fails, and the footprint recorder.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the cache path. The test also asserts that the capture saw at least one record, so that a test that sees nothing fails.
- [ ] One integration test in `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/MLXModelLoaderIntegrationTests.swift` that loads the real model and checks the load span and its phase child spans. Run it with `swift test --package-path IntegrationTests --filter MLXModelLoaderIntegrationTests`.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature