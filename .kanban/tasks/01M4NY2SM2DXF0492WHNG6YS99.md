---
assignees:
- claude-code
depends_on:
- 01M4NY251FHKTW3HFKQ5J5A6HJ
position_column: todo
position_ordinal: 8d80
title: 'Marketplace cache telemetry: writer-lock conflicts, install time, and removed snapshots'
---
## What

The marketplace cache installs snapshots, swaps the `current` link, removes old snapshots and takes a writer lock, but it records no telemetry. Two writers that conflict, a slow install or many removed snapshots show nothing. This task uses the `Marketplace` telemetry API and the vocabulary file `Sources/Marketplace/MarketplaceTelemetry.swift` of task `5j5a6hj`.

The span of the snapshot write and the counter of snapshot reuse are in task `v0vkfeh`.

Files and points:
- `Sources/Marketplace/MarketplaceCache.swift`:
  - `installValidated(snapshotAt:checked:)`. Both `install(snapshotAt:sha:ref:)` (`:451`) and `installUnderWriterLock` call it.
  - `removeUnusedSnapshots(keeping:)` (`:655`).
  - `withWriterLock(_:)` (`:697`) and `withWriterLock(isolation:_:)` (`:725`). The lock never waits (`MarketplaceCacheError.writerLockHeld`, `:23-27`; `LOCK_NB` in `openWriterLock()`, `:735-764`): a folder that another writer holds gives `writerLockHeld` at once.

Approach (each name in `MarketplaceTelemetry.swift`, metric objects made at call time):
- Counter of writer-lock conflicts: one count each time `openWriterLock()` throws `writerLockHeld`. The lock never waits, thus record a count, not a wait time.
- Timer of the install duration in `installValidated(snapshotAt:checked:)`, with the outcome. Both install paths then record it one time.
- Counter of removed snapshots: one count for each snapshot that `removeUnusedSnapshots(keeping:)` deletes.
- Attribute `marketplace.id` (the display id) where it is known. Never record a path (also not the `path` of `writerLockHeld` or `cannotLock`), a URL or a credential.

## Acceptance Criteria
- [ ] Each `writerLockHeld` adds one count to the writer-lock conflict counter.
- [ ] Each install records one duration with its outcome, from `installValidated(snapshotAt:checked:)`, for both `install` and `installUnderWriterLock`.
- [ ] Each removed snapshot adds one count.
- [ ] No span, log record or metric carries a path.

## Tests
- [ ] `Tests/MarketplaceTests/MarketplaceCacheTests.swift`: with `MetricsTestKit` `TestMetrics`, test the conflict count with a held writer lock and the removed-snapshot count.
- [ ] `Tests/MarketplaceTests/MarketplaceStoreTests.swift`: test the install timer through the store path (a pass that installs a new snapshot records one install duration), plus a content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the cache path and the lock file path. The test also asserts that the capture saw at least one record.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature