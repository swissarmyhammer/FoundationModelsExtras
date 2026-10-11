---
assignees:
- claude-code
depends_on:
- 01M4NXZ87GYNQQPZAEZTSXP83P
position_column: todo
position_ordinal: '8880'
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
- [ ] Each acquire records one `FoundationModelsExtras.pool.acquires` count with the correct `cache.result` (`hit`, `late_hit` or `load`).
- [ ] Each eviction records one `FoundationModelsExtras.pool.evictions` count and one `FoundationModelsExtras.pool.idle_to_evict` duration. A skipped eviction records `reason=rehold` and no duration.
- [ ] The four meters `FoundationModelsExtras.pool.resident_bytes`, `FoundationModelsExtras.pool.loading_bytes`, `FoundationModelsExtras.pool.evicting_bytes` and `FoundationModelsExtras.pool.resident_models` agree with `ModelPool.footprint` and `residentModelCount` after each change.
- [ ] A caller that joins a running load in `ResidentHold` adds one `FoundationModelsExtras.pool.load_joins` count. A failed measure writes one log record with `error.type` and no description.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift`: with `MetricsTestKit` `TestMetrics` and the fake loaders of `ModelPoolTestSupport.swift`, test the hit, late hit and load counts, the eviction count and timer, the rehold skip, and the meter values.
- [ ] A test of `FoundationModelsExtras.pool.load_joins` with two callers of one `ResidentHold` (for example in `PooledModelTests.swift`).
- [ ] A test of the measure-failure log record with a loader whose `footprintBytes(of:)` throws, plus a content-safety test with `TelemetryCapture.run(forbidding:)`. The content-safety test also asserts that the capture saw at least one record, so that a test that sees nothing fails.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature