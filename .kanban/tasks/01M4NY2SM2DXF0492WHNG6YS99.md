---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4rf53nvqs87xyafe6m6h6da
  text: |-
    Research done.
    - MarketplaceCache does not know the display id. The store makes each cache in `addGit` (and the seed cache in `kind(ofRemote:folderName:)`) and has the pre-fetch key there, which is the display id (`displayID(atIndex:)` gives `prepared[index].key`). Plan: give MarketplaceCache a `marketplaceID` stored property; the store passes the key. Four call sites make a cache: two in the store, `MarketplaceCacheTests.CacheFixture`, `MarketplacePinTests.cache(inCacheOf:)`.
    - `installValidated` is synchronous, thus `traceGitCall` (async) cannot time it. Plan: one synchronous timer helper in the vocabulary that shares the private `recordDuration` with `traceGitCall`.
    - The install outcome has the same two values as `MarketplaceGitOutcome`. To keep one enum, rename it to `MarketplaceCallOutcome` and add the dimension key `install.outcome`.
    - The store content-safety test needs the lock file path before the pass. `MarketplacePolicyTests.cacheFolder(of:inDirectory:)` and `MarketplaceListingTests.write(record:...)` each compute the cache folder of a source. Plan: one shared helper in `MarketplaceTestSupport` that gives the cache of a source, and both tests use it.
  timestamp: 2026-10-12T16:29:25.051311+00:00
- actor: claude-code
  id: 01m4rfjewr7m8tyjcq2v997p0z
  text: |-
    Implementation landed (TDD: the 7 new tests failed first on a missing metric, then passed).
    - Vocabulary (`MarketplaceTelemetry.swift`): metric names `Marketplace.install.duration`, `Marketplace.writer_lock.conflicts`, `Marketplace.snapshots.removed`; dimension key `install.outcome`. `MarketplaceGitOutcome` is now `MarketplaceCallOutcome` (one enum for the git timers and the install timer). New `timeInstall(id:_:)` (synchronous form of the timer step of `traceGitCall`, because Swift has no `reasync`) and `count(_:id:)`. The private `recordDuration` takes the outcome key; both timers use it. Both timer helpers record through one `defer`, on the success path and the error path.
    - Cache: new `marketplaceID` property (the display id); the store passes the pre-fetch key. `installValidated` runs in `timeInstall`; `removeSnapshot` counts after each real delete; `openWriterLock` counts each `EWOULDBLOCK` before it throws `writerLockHeld`. No path goes into a dimension.
    - Tests: 5 cache tests (conflict count, removed count, no count for a held snapshot, install success and failure durations), 2 store tests (install duration through the store path; content safety that forbids the cache path and the lock file path and makes a real writer-lock conflict). New shared helpers in `MarketplaceTelemetryExpectations` (`installDurations`, `cacheCounts`, `expectNoCounter`) and `MarketplaceTestSupport.cache(of:inCacheDirectory:)`; the two copies of the cache-folder computation in the policy and listing tests now use the shared helper.
    - Discovery: `#expect(throws: CocoaError.self)` matches the failed `moveItem` of a missing staged folder.

    ### implement — changed
    - evidence: `swift test` — every suite passed (1052 tests in 92 suites with the 11 known issues of the TelemetryCapture self-tests, 400 tests in 29 suites, and the other runs); only warning is the mlx-swift bundle line. Files: Sources/Marketplace/MarketplaceTelemetry.swift, Sources/Marketplace/MarketplaceCache.swift, Sources/Marketplace/MarketplaceStore.swift, Tests/MarketplaceTests/MarketplaceCacheTests.swift, Tests/MarketplaceTests/MarketplaceStoreTests.swift, Tests/MarketplaceTests/MarketplaceTelemetryExpectations.swift, Tests/MarketplaceTests/MarketplaceTelemetryTests.swift, Tests/MarketplaceTests/MarketplaceTestSupport.swift, Tests/MarketplaceTests/MarketplacePinTests.swift, Tests/MarketplaceTests/MarketplacePolicyTests.swift, Tests/MarketplaceTests/MarketplaceListingTests.swift
    - next: /review
  timestamp: 2026-10-12T16:36:42.520547+00:00
depends_on:
- 01M4NY251FHKTW3HFKQ5J5A6HJ
position_column: doing
position_ordinal: '80'
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
- [x] Each `writerLockHeld` adds one count to the writer-lock conflict counter.
- [x] Each install records one duration with its outcome, from `installValidated(snapshotAt:checked:)`, for both `install` and `installUnderWriterLock`.
- [x] Each removed snapshot adds one count.
- [x] No span, log record or metric carries a path.

## Tests
- [x] `Tests/MarketplaceTests/MarketplaceCacheTests.swift`: with `MetricsTestKit` `TestMetrics`, test the conflict count with a held writer lock and the removed-snapshot count.
- [x] `Tests/MarketplaceTests/MarketplaceStoreTests.swift`: test the install timer through the store path (a pass that installs a new snapshot records one install duration), plus a content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the cache path and the lock file path. The test also asserts that the capture saw at least one record.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature