---
assignees:
- claude-code
depends_on:
- 01M4NY08T0DMYJ1BVEG8R1175P
position_column: todo
position_ordinal: '9080'
title: 'Model telemetry: log the prewarm error and time each eviction'
---
## What

Two model paths give no telemetry:
- `PooledModel.prewarm(transcript:)` (`Sources/FoundationModelsExtras/ModelPool/PooledModel.swift:106-108`) drops its error with `try?` (`:108`).
- An eviction has no timer: `MLXModelLoader.evict(_:)` (`Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift:112`), and the evict part of `ModelPool.evictIfIdle(_:)` (`Sources/FoundationModelsExtras/ModelPool/ModelPool.swift`).

This task was part of task `8r1175p`.

Approach (each name in `ExtrasTelemetry.swift`, metric objects made at call time):
- `prewarm`: replace the silent `try?` with a `do`/`catch` that writes one log record with `error.type` (`ExtrasTelemetry.errorType`) and `model.ref`.
- Timer `FoundationModelsExtras.model.evict.duration` with `model.ref`, `model.role` (`llm` or `embedding`) and the outcome (`succeeded` or `failed`). Record it around the evict call in `evictIfIdle`, so that each loader gets it.
- Never record a file path, a cache folder, a URL or `error.localizedDescription`.

## Acceptance Criteria
- [ ] A `prewarm` that fails writes one log record with `error.type` and `model.ref`, and no description.
- [ ] Each eviction records one duration on `FoundationModelsExtras.model.evict.duration` with `model.ref`, `model.role` and the outcome.
- [ ] Each new name starts with `FoundationModelsExtras.`.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift`: a `prewarm` that throws writes one log record with `error.type`.
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`: with a fake loader from `ModelPoolTestSupport.swift` and `MetricsTestKit` `TestMetrics`, test the evict timer for an eviction that succeeds and one that fails.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the cache path. The test also asserts that the capture saw at least one record, so that a test that sees nothing fails.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature