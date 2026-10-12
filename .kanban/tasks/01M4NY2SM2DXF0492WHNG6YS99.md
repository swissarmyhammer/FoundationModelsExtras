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
- actor: claude-code
  id: 01m4rfx3te7wjr87r1bv8crafr
  text: |-
    ### review — findings
    - evidence: review sha 70dd3b1~1..70dd3b1 — 1 finding (1 confirmed, 0 refuted) — Sources/Marketplace/MarketplaceCache.swift:499
    - next: /implement the open item in the "Review Findings (2026-10-12 11:39)" section
  timestamp: 2026-10-12T16:42:31.630668+00:00
- actor: claude-code
  id: 01m4rfx4eqa9736anc8py6xvw6
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files
    - test: green — swift test, 1052 passed
    - commit: 70dd3b1
    - review: findings — Sources/Marketplace/MarketplaceCache.swift:499
  timestamp: 2026-10-12T16:42:32.279302+00:00
- actor: claude-code
  id: 01m4rg6mch6ywcjkveq0fg19gj
  text: |-
    Finding fix landed (TDD: the 3 new tests, 33 cases, failed first with `missingMetric install.duration failed`, then passed).
    - Cause: the install timer started in `installValidated`, after the checks. Two paths threw before the timer: `Self.validated(sha:ref:)` in both `install` and `installUnderWriterLock`, and also `makeFolders()` and `withWriterLock` (a `writerLockHeld`) in `install`. Each of these recorded no duration.
    - Fix: new private `timedInstall(sha:ref:_:)` in `MarketplaceCache.swift`. It starts the timer, then runs the check, then the steps. Both entry points call it, so each install call records one duration; a refused sha or ref, a held writer lock, a folder error and a failed swap each record `failed`. `installValidated` now holds no timer, and its doc says so. The check still runs before `makeFolders()`, so a refused value still writes nothing.
    - Other counted steps checked: the writer-lock conflict counter sits at the only `writerLockHeld` throw site; the removed-snapshot counter sits after the only snapshot delete (`removeSnapshot`), which every cleanup path uses. No gap there.
    - Tests: `anInstallWithAnUnsafeShaRecordsOneFailedInstallDuration` and `anInstallWithAnUnsafeRefRecordsOneFailedInstallDuration` (each over both entry points and every unsafe value), `anInstallThatFindsTheWriterLockHeldRecordsOneFailedInstallDuration`. Each asserts one `failed` install duration and no `succeeded` one. New shared helper `MarketplaceTelemetryExpectations.expectNoInstallDuration(_:in:)`; new fixture entry `CacheFixture.install(through:snapshotAt:sha:ref:)` with the `InstallEntry` enum.
    - Note: the card text still names `installValidated` as the timer site. The timer is now one level up, in `timedInstall`, which both entry points call.

    ### implement — changed
    - evidence: `swift test` — 1052 tests in 92 suites passed (11 known issues of the TelemetryCapture self-tests), 403 tests in 29 suites passed, the other runs passed; only warning is the mlx-swift bundle line of the build tool. Files: Sources/Marketplace/MarketplaceCache.swift, Tests/MarketplaceTests/MarketplaceCacheTests.swift, Tests/MarketplaceTests/MarketplaceTelemetryExpectations.swift
    - next: /review
  timestamp: 2026-10-12T16:47:43.505417+00:00
- actor: claude-code
  id: 01m4rgd6ztfanfzj77jfmmj4bh
  text: |-
    ### review — clean
    - evidence: review sha 20eb203~1..20eb203 — 0 findings (0 confirmed, 1 refuted, 7 attempted, 0 failed). The prior item in "Review Findings (2026-10-12 11:39)" is checked.
    - next: none. The task is in done.
  timestamp: 2026-10-12T16:51:19.162463+00:00
- actor: claude-code
  id: 01m4rgd7rw162rt7t83czyk2fs
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files
    - test: green — swift test, 1052 passed
    - commit: 20eb203
    - review: clean — 0 findings
  timestamp: 2026-10-12T16:51:19.964769+00:00
depends_on:
- 01M4NY251FHKTW3HFKQ5J5A6HJ
position_column: done
position_ordinal: fd80
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

## Review Findings (2026-10-12 11:39)

> Scope: `review sha 70dd3b1~1..70dd3b1` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/Marketplace/MarketplaceCache.swift:499` `completeness/invariant-propagation` — The doc comment says each install records one duration on the install timer, with its outcome. But `installUnderWriterLock` (line 481, unmarked) runs `Self.validated(sha:ref:)` before `installValidated` starts the timer. A commit or ref that fails validation throws before `timeInstall` runs, so that install records no duration and no `failed` outcome. The comment and the code disagree for this input, and the failure is not visible on the install timer. Either move the validation inside the timed region, so a refused commit or ref records a `failed` install outcome, or narrow the doc comment to say that only the publish and activate steps are timed. If you move it, add one test that installs with an unsafe sha and asserts one `failed` install duration.
