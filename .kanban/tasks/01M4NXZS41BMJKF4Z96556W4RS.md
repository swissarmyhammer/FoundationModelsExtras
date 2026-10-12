---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4qy3gwv9kyb2j84pqacc34z
  text: |-
    Research done.
    - The admission job runs on a detached task (GenerationQueue). The job restores the trace context, the tracer and the metrics factory of the submitter. Thus the metrics of load, loadMeasured and evictIfIdle reach the factory of the submitter. The eviction job gets the factory of the task that dropped the last hold (ModelHold.deinit calls release, and release enqueues the job).
    - The log record of a failed measure is written inside the admission job. TelemetryCapture routes each log record through a test task-local (TelemetryLogRouting.currentContext), and a detached job does not inherit it. Thus a capture cannot see that record now. Plan: TelemetryCapture.run also puts its context in ServiceContext, and the routing handler falls back to ServiceContext.current. The queue job restores ServiceContext, so the capture then sees log records of queue jobs. This is a small change to Tests/TelemetryTestSupport.
    - ResidentHold does not know the model ref, so load_joins has no dimension (the card names none).
    - A second eviction job can find no entry (the first job already evicted the model). That is not a rehold, so it records nothing. Only an entry with holds > 0 records reason=rehold.
  timestamp: 2026-10-12T11:31:27.259956+00:00
- actor: claude-code
  id: 01m4qysrjsx7xs6vtb06h18xs1
  text: |-
    Implementation landed (TDD: each new test failed first for the expected reason, then passed).
    - New `Telemetry/PoolTelemetry.swift`: one recorder of the pool metrics and the measure-failure log record. All names are in `ExtrasTelemetry.swift` (MetricName.pool*, DimensionKey.cacheResult/evictionReason, LogMetadataKey.errorType/modelRef, PoolLogMessage, enums PoolCacheResult and PoolEvictionSkipReason).
    - ModelPool: `holdIfResident(_:sessionBytes:counting:)` counts hit (ModelPool) or late_hit (ModelPoolAdmission) after the locks; load/loadMeasured count load; the entry keeps `releasedAt`; `evictIfIdle` uses `State.startEviction(of:at:)` that gives an `EvictionStart` enum (evict with idle time, rehold, gone). The move to the evicting models now goes through `publish` with no streams, so the meters see the evicting bytes and the streams get no extra value. `publish` sets the four meters after the state lock and before the yield (under the publish lock, as the yield is), so the meters see the changes in order.
    - Real evictions have the dimension `model.ref` only, as the card says; a skipped eviction has `model.ref` and `reason=rehold`. An eviction job that finds no entry (an earlier job evicted the model) records nothing.
    - ResidentHold: `Access` now has `.started` and `.joined`; `.joined` counts one load join after the lock. The counter has no dimension (ResidentHold does not know the model ref; the card names none).
    - Test support: TelemetryCapture now also puts its context in ServiceContext, and the routing log handler falls back to it. Without this, a log record written in an admission job (a detached task) never reached the capture. New test in TelemetryCaptureTests proves it.
    - What did not work: a load-join test through `PooledModel.session()` saw no join, because `session()` calls `pool.acquire` and not `ResidentHold.loaded()`. The final test calls two callers of one ResidentHold. A meters test that took the hold as a Task value never evicted, because a Task keeps its value; the test now uses `HoldSlot`.
    - Full `swift test`: 994 tests in 90 suites passed, 11 known issues (the existing withKnownIssue tests of TelemetryCaptureTests). The only warning is the mlx-swift "missing creator for mutated node" line from the dependency build.
  timestamp: 2026-10-12T11:43:36.025793+00:00
- actor: claude-code
  id: 01m4qysw2srjvs7y5ha9brscb0
  text: |-
    ### implement — changed
    - evidence: `swift test` 994 tests / 90 suites passed (11 known issues, existing). Files: Sources/FoundationModelsExtras/Telemetry/PoolTelemetry.swift (new), Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Sources/FoundationModelsExtras/ModelPool/ModelPool.swift, Sources/FoundationModelsExtras/ModelPool/ResidentHold.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryCaptureTests.swift, Tests/TelemetryTestSupport/TelemetryCapture.swift, Tests/TelemetryTestSupport/TelemetryLogRouting.swift
    - next: review
  timestamp: 2026-10-12T11:43:39.609499+00:00
depends_on:
- 01M4NXZ87GYNQQPZAEZTSXP83P
position_column: doing
position_ordinal: '80'
title: 'Pool cache telemetry: acquire hit/late hit/load, evictions, holds, and the footprint as gauges'
---
## What

`ModelPool` (`Sources/FoundationModelsExtras/ModelPool/ModelPool.swift:8`) is a cache of loaded models, but it records no metric. An operator cannot see the hit rate, the evictions or the memory of the pool.

Approach (each name in `ExtrasTelemetry.swift`, metric objects made at call time, `model.ref` = `ModelRef.stringValue`, `ModelRef.swift:67`):
- Counter `FoundationModelsExtras.pool.acquires` with `model.ref` and `cache.result`:
  - `hit`: the fast path `holdIfResident` in `ModelPool.acquire(_:)` (`:105`) and `acquire(_:footprintBytes:sessionBytes:loader:)` (`:119`).
  - `late_hit`: the model is resident after the admission wait, in `ModelPoolAdmission.acquire(_:footprintBytes:sessionBytes:loader:)` (`:397`) and `ModelPoolAdmission.acquire(_:)` (`:408`).
  - `load`: the call loads the model (`load`, `:210`, or `loadMeasured`, `:230`).
- Counter `FoundationModelsExtras.pool.evictions` with `model.ref`, recorded in `evictIfIdle(_:)` (`:322`) when the evict call returns (`:329-330`). When the guard at `:324` finds a new hold and skips the eviction (`guard let idle else { return }`, `:328`), count it with `reason=rehold`.
- Timer `FoundationModelsExtras.pool.idle_to_evict` with `model.ref`: the time from the last release (`release(_:sessionBytes:)`, `:305`, when `holds == 0` at `:311`) to the eviction. Keep the release instant in the entry.
- Meters `FoundationModelsExtras.pool.resident_bytes`, `FoundationModelsExtras.pool.loading_bytes`, `FoundationModelsExtras.pool.evicting_bytes` and `FoundationModelsExtras.pool.resident_models`, set from the footprint in `publish(_:)` (`:340`; the footprint is computed at `:346`). Set them outside the state lock, as the yield to the streams is.
- In `ResidentHold.loaded()` (`Sources/FoundationModelsExtras/ModelPool/ResidentHold.swift:54`), count each caller that joins a load that another caller started (Counter `FoundationModelsExtras.pool.load_joins`): the `.loading` case of `access(state:)` (`:67`), not the `.unloaded` case that starts the load (`:73-76`).
- When the measure fails in `loadMeasured` (`ModelPool.swift:235-238`, `footprintBytes(of:)` throws and the loader evicts the model), write one log record with `error.type` (`ExtrasTelemetry.errorType`) and `model.ref`. Never write `error.localizedDescription`.
- Never record a file path, a prompt or a container description.

## Acceptance Criteria
- [x] Each acquire records one `FoundationModelsExtras.pool.acquires` count with the correct `cache.result` (`hit`, `late_hit` or `load`).
- [x] Each eviction records one `FoundationModelsExtras.pool.evictions` count and one `FoundationModelsExtras.pool.idle_to_evict` duration. A skipped eviction records `reason=rehold` and no duration.
- [x] The four meters `FoundationModelsExtras.pool.resident_bytes`, `FoundationModelsExtras.pool.loading_bytes`, `FoundationModelsExtras.pool.evicting_bytes` and `FoundationModelsExtras.pool.resident_models` agree with `ModelPool.footprint` and `residentModelCount` after each change.
- [x] A caller that joins a running load in `ResidentHold` adds one `FoundationModelsExtras.pool.load_joins` count. A failed measure writes one log record with `error.type` and no description.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`: with `MetricsTestKit` `TestMetrics` and the fake loaders of `ModelPoolTestSupport.swift`, test the hit, late hit and load counts, the eviction count and timer, the rehold skip, and the meter values.
- [x] A test of `FoundationModelsExtras.pool.load_joins` with two callers of one `ResidentHold` (for example in `PooledModelTests.swift`).
- [x] A test of the measure-failure log record with a loader whose `footprintBytes(of:)` throws, plus a content-safety test with `TelemetryCapture.run(forbidding:)`. The content-safety test also asserts that the capture saw at least one record, so that a test that sees nothing fails.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature