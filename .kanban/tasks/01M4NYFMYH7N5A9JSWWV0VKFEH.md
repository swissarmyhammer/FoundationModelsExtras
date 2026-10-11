---
assignees:
- claude-code
depends_on:
- 01M4NY2SM2DXF0492WHNG6YS99
position_column: todo
position_ordinal: '9380'
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
- [ ] Each snapshot write opens one span with the file count and the byte count.
- [ ] Each served marketplace adds one count with `snapshot.source` = `seed`, `current` or `installed`.
- [ ] No span, log record or metric carries a path.
- [ ] Each new name starts with `Marketplace.`.

## Tests
- [ ] `Tests/MarketplaceTests/SnapshotWriterTests.swift`: with `W3CInMemoryTracer`, test the write span and its file count and byte count.
- [ ] `Tests/MarketplaceTests/MarketplaceStoreTests.swift`: with `MetricsTestKit` `TestMetrics`, test the reuse counter for a seed, a current snapshot and a new install.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the cache path. The test also asserts that the capture saw at least one record.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature