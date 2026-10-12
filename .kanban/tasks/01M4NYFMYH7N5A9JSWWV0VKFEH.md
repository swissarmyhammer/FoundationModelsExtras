---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4rgpjmj7xb5mkn01j24vqmk
  text: |-
    Research done.
    - `SnapshotWriter.write` is synchronous. `TracedCall.run` is async only, and the core has no synchronous span helper. Plan: make `write` `nonisolated(nonsending) async`, run it through `MarketplaceTelemetry.traceStep`, and give `traceStep` the open span so that the writer sets the file count and the byte count in a `defer` (thus a refused write also records its counts and its `error.type`). `materialize` in the store becomes async. The writer gets a `marketplaceID` parameter for the `marketplace.id` attribute.
    - Serve points: `servedFromDisk` at init (`.git` with a `current` snapshot gives `current`, `.seed` gives `seed`), and `serve(atIndex:cache:sha:)` after an install or after the adopt of a pending snapshot (gives `installed`). A git source with no snapshot yet and a local folder serve no snapshot, thus they count nothing.
    - `MarketplaceTelemetry.count(_:id:)` gets extra dimensions, so the pass counter and the new served-snapshot counter use one counter recorder.
  timestamp: 2026-10-12T16:56:26.002014+00:00
- actor: claude-code
  id: 01m4rhaxnzk4qtmjypb3zddvhy
  text: |-
    Implementation landed.
    - Vocabulary: span `Marketplace.snapshot_write`, attributes `snapshot.file_count` and `snapshot.byte_count`, counter `Marketplace.snapshots.served` with dimension `snapshot.source`, enum `MarketplaceSnapshotSource` (`seed`, `current`, `installed`). `traceStep` now gives its body the open span. `count(_:id:dimensions:)` is the one counter recorder; the private `makePassCounter` is gone, and `tracePass` and `countServedSnapshot(from:id:)` use `count`.
    - `SnapshotWriter.write` is now `nonisolated(nonsending) async` and takes `marketplaceID:`. It runs in `traceStep`, and a `defer` records the counts, thus a refused write also records them, with `error.type` from `TracedCall`.
    - Store: `servedFromCache` counts `current` or `seed` when the folder holds a snapshot (it takes `source:` in place of `leased:`; the lease rule is now `source != .seed`). `serve(atIndex:cache:sha:)` counts `installed` (install and pending-snapshot adopt).
    - Tests: `SeedFixture` moved from `MarketplaceLocalSourceTests` to `MarketplaceTestSupport.swift` with a new `makeStore()`, so the store suite reuses it. `MarketplaceTelemetryExpectations` got `expectSnapshotCounts`, `servedCounts`, and one private `counts(of:in:id:dimensions:)` that `passCounts` and `cacheCounts` now share. `SnapshotWriterTests` helpers and tests are async; `oneFileLimits` replaces two inline copies.
    - What did not work: the `files` tool `replace_all` made one replacement only, thus `SnapshotWriterTests.swift` was rewritten whole.
    - Verified: `swift build --build-tests` has no error and no warning (the mlx `missing creator` line only). Full `swift test`: 1052 tests in 92 suites passed (11 known issues are existing `withKnownIssue` tests); MarketplaceTests 410 tests in 29 suites passed. After the last test-only edit, the three changed suites: 81 tests passed.

    ### implement — changed
    - evidence: 8 files — Sources/Marketplace/MarketplaceTelemetry.swift, Sources/Marketplace/SnapshotWriter.swift, Sources/Marketplace/MarketplaceStore.swift, Tests/MarketplaceTests/SnapshotWriterTests.swift, Tests/MarketplaceTests/MarketplaceStoreTests.swift, Tests/MarketplaceTests/MarketplaceTelemetryExpectations.swift, Tests/MarketplaceTests/MarketplaceTestSupport.swift, Tests/MarketplaceTests/MarketplaceLocalSourceTests.swift; swift test 1052 passed, 0 failed
    - next: /review
  timestamp: 2026-10-12T17:07:32.671305+00:00
- actor: claude-code
  id: 01m4rhpn6yyxz0rbpy6eth3w8m
  text: |-
    ### review — findings
    - evidence: review sha 92bef4f~1..92bef4f; 1 finding (1 confirmed, 0 refuted) — Tests/MarketplaceTests/MarketplaceTestSupport.swift:66
    - next: /implement the open item in the Review Findings (2026-10-12 12:10) section
  timestamp: 2026-10-12T17:13:57.214070+00:00
- actor: claude-code
  id: 01m4rhprz43gfyn52dmw2wkxfy
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test, 1052 passed
    - commit: 92bef4f
    - review: findings — Tests/MarketplaceTests/MarketplaceTestSupport.swift:66
  timestamp: 2026-10-12T17:14:01.060540+00:00
- actor: claude-code
  id: 01m4rhwn15akkn06eywwx2axsd
  text: |-
    Finding `swift/initialization` (MarketplaceTestSupport.swift, SeedFixture init) is fixed.
    - `SeedFixture` now has a `private init(repository:seedDirectory:seededSha:fixture:)` that only assigns, and a `static func make() async throws -> SeedFixture` factory that makes the commit, writes the seed folder, awaits `seeding.store.start()`, and builds the store under test. A factory and not `func seed()`: the stored properties come from the seed result, and the rule "No stored property waits for a later method to fill it in" forbids a `seed()` method that sets them later.
    - The 4 callers (2 in MarketplaceLocalSourceTests, 2 in MarketplaceStoreTests) call `SeedFixture.make()`. No helper was copied.
    - The other declarations in MarketplaceTestSupport.swift (CredentialRequestRecorder, MarketplaceTestSupport, SnapshotLockProbe, OpenDescriptorProbe) have no `init` with work, thus they need no change.
    - Again: the `files` tool `replace_all` made one replacement only; each second call was edited one at a time.

    ### implement — changed
    - evidence: 3 files — Tests/MarketplaceTests/MarketplaceTestSupport.swift, Tests/MarketplaceTests/MarketplaceLocalSourceTests.swift, Tests/MarketplaceTests/MarketplaceStoreTests.swift; `swift test --filter 'Marketplace|SnapshotWriter'` 410 tests in 29 suites passed; `swift test` 1052 tests in 92 suites passed (11 known issues are existing `withKnownIssue` tests); no compiler warning (the mlx `missing creator` build line only)
    - next: /review
  timestamp: 2026-10-12T17:17:13.637350+00:00
- actor: claude-code
  id: 01m4rj25208byyjft0w89ja1j3
  text: |-
    ### review — clean
    - evidence: review sha 2bfc6d5~1..2bfc6d5; 0 findings (0 confirmed, 0 refuted); 3 files reviewed; all prior items checked
    - next: none — task moved to done
  timestamp: 2026-10-12T17:20:13.888065+00:00
- actor: claude-code
  id: 01m4rj27zhxbkk99mhss8bsf0y
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files
    - test: green — swift test, 1052 passed
    - commit: 2bfc6d5
    - review: clean — 0 findings
  timestamp: 2026-10-12T17:20:16.881817+00:00
depends_on:
- 01M4NY2SM2DXF0492WHNG6YS99
position_column: done
position_ordinal: fe80
title: 'Marketplace telemetry: a span for the snapshot write and a counter of snapshot reuse'
---
## What

The snapshot write and the reuse of a snapshot give no telemetry. A large snapshot, or a store that installs again when it can use a snapshot, shows nothing. This task uses the `Marketplace` telemetry API and the vocabulary file `Sources/Marketplace/MarketplaceTelemetry.swift` of task `5j5a6hj`. This task was part of task `ng6ys99`.

Files and points:
- `Sources/Marketplace/SnapshotWriter.swift`: `write(catalog:from:to:layout:limits:)` (`:116`).
- `Sources/Marketplace/MarketplaceStore.swift`: the store serves a marketplace from the current snapshot of the cache or from the read-only seed folder (`:1242-1247`).

Approach (each name in `MarketplaceTelemetry.swift`, metric objects made at call time):
- Span for the snapshot write in `SnapshotWriter.write`, with the file count and the byte count.
- Counter of snapshot reuse against a new install, with a fixed `snapshot.source` dimension: `seed`, `current` or `installed`.
- Attribute `marketplace.id` (the display id) where it is known. Never record a path, a URL or a credential.

## Acceptance Criteria
- [x] Each snapshot write opens one span with the file count and the byte count.
- [x] Each served marketplace adds one count with `snapshot.source` = `seed`, `current` or `installed`.
- [x] No span, log record or metric carries a path.
- [x] Each new name starts with `Marketplace.`.

## Tests
- [x] `Tests/MarketplaceTests/SnapshotWriterTests.swift`: with `W3CInMemoryTracer`, test the write span and its file count and byte count.
- [x] `Tests/MarketplaceTests/MarketplaceStoreTests.swift`: with `MetricsTestKit` `TestMetrics`, test the reuse counter for a seed, a current snapshot and a new install.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the cache path. The test also asserts that the capture saw at least one record.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature

## Review Findings (2026-10-12 12:10)

> Scope: `review sha 92bef4f~1..92bef4f` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/MarketplaceTests/MarketplaceTestSupport.swift:66` `swift/initialization` — The init of SeedFixture does slow work. It makes a git commit, writes the seed folder, and awaits seeding.store.start(), which runs a git fetch. A caller of init must wait for all of this before the fixture exists, and a failed fetch is hidden in the init path. Move the seed work (lines 67-73) into an explicit async throws method, for example func seed() async throws, that the test calls before it uses store. Keep init to plain assignments, or build only the fixture values in init.
