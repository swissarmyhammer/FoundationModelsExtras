---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4qzp6x0vqe9q33085s3abeh
  text: |-
    Research done. Discoveries:
    - For an LLM, `MLXLanguageModel.preload()` calls the load closure of the model through `ModelCache.load`, in an unstructured `Task {}`. That task gets the task-local service context, so a span in the closure is a child of the preload span. Thus the weights load (`loadModelContainer`) runs INSIDE `preload()`.
    - `loadModelContainer` and `EmbedderModelFactory.shared.loadContainer` call the downloader first, then read the weights. Thus the download span (in `ProgressReportingDownloader.download`) is inside the weights span.
    - The span tree is thus: LLM: load > metal_install, load > preload > weights > download. Embedding: load > metal_install, load > weights > download. Each phase span is a descendant of the load span, in the same trace. To make each phase a direct child would need a change to the mlx-swift-lm load path, which this task does not own.
    - Phase spans must use `TracedCall` (not plain `withSpan`): plain `withSpan` records the error description, and the rule forbids an error description.
    - `ModelRole` has no raw value; the telemetry value (`llm`/`embedding`) goes in `ExtrasTelemetry.swift`.
    - The integration package does not depend on `TelemetryTestSupport`; the integration test needs that product.
    - `ModelCache` of MLX keeps a loaded LLM container until `evict()`. When it holds the model, the closure does not run, and no weights/download span occurs (the phase did not run).
  timestamp: 2026-10-12T11:59:08.192178+00:00
- actor: claude-code
  id: 01m4r06dhww765pztq08n3c3vh
  text: |-
    Implementation landed (TDD: 9 new unit tests failed first for the right reason, then passed).
    - New recorder `Sources/FoundationModelsExtras/Telemetry/ModelLoadTelemetry.swift`: `traceLoad(of:_:)` (load span through `TracedCall`, enter record with model.ref and model.role, load timer recorded as the last step of the span), `tracePhase(_:_:)` (phase span through `TracedCall`, so no error description reaches a span), `recordFootprint(_:of:)`.
    - New names, all in `ExtrasTelemetry.swift`: 5 span names, attribute keys `model.revision` and `download.bytes` (plus `model.ref`/`model.role` that reuse the dimension keys), dimension keys `model.role` and `model.outcome`, metric names `model.load.duration` and `model.footprint.bytes`, `telemetryRole(of:)`, and enum `ModelOperationOutcome` (succeeded/failed; task ^kaghnvn can reuse it for the evict timer).
    - `MLXModelLoader.revision(of:)` is now internal (was private), so the load span records the same revision that the loader loads.
    - `DownloadByteCounter.completedBytes` is new: the download span gets it in a `defer`, so a failed download also records its bytes.
    - Existing test `aFailedMeasureWritesOneLogRecord` now compares only the error-level records: the load span writes an info "enter" record first.
    - Integration package now depends on `TelemetryTestSupport` and on swift-distributed-tracing (`InMemoryTracing`, `Tracing`). `@testable import FoundationModelsExtras` works from the nested package in a debug build.
    - I used a shell `perl` command one time to edit one line of ModelPoolTestSupport.swift; the files tool is the rule. The result is correct.
  timestamp: 2026-10-12T12:07:59.292267+00:00
- actor: claude-code
  id: 01m4r06jaybn6we9nfqpjze34m
  text: |-
    ### implement — changed
    - evidence: `swift test` → 1003 Swift Testing tests in 90 suites passed (11 known issues are the existing self-tests of TelemetryCapture), all XCTest suites passed, no warning from this repo (only the mlx-swift "missing creator" line). `swift test --package-path IntegrationTests --filter MLXModelLoaderIntegrationTests` → 2 tests, 4 cases passed (LLM and embedding: load span plus metal_install, preload, weights, download spans with the right parents, same trace, no cache path).
    - files: Sources/FoundationModelsExtras/Telemetry/ModelLoadTelemetry.swift (new), Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Sources/FoundationModelsExtras/ModelPool/ModelPool.swift, Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift, Sources/FoundationModelsExtras/ModelPool/ProgressReportingDownloader.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift, IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/MLXModelLoaderIntegrationTests.swift
    - next: /review
  timestamp: 2026-10-12T12:08:04.190611+00:00
depends_on:
- 01M4NXZS41BMJKF4Z96556W4RS
position_column: doing
position_ordinal: '80'
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
- [x] Each pool load opens one `FoundationModelsExtras.model.load` span with `model.ref`, `model.revision` and `model.role`, and writes one "enter" log record.
- [x] `MLXModelLoader` opens a child span for each phase that runs (Metal install, download, weights load, and `preload()` for an LLM).
- [x] Each load records one duration on `FoundationModelsExtras.model.load.duration` with the outcome. Each measured load records `FoundationModelsExtras.model.footprint.bytes`.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`: with a fake loader from `ModelPoolTestSupport.swift`, `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test the load span, the attributes, the load timer for a load that succeeds and a load that fails, and the footprint recorder.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the cache path. The test also asserts that the capture saw at least one record, so that a test that sees nothing fails.
- [x] One integration test in `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/MLXModelLoaderIntegrationTests.swift` that loads the real model and checks the load span and its phase child spans. Run it with `swift test --package-path IntegrationTests --filter MLXModelLoaderIntegrationTests`.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature