---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'MarketplaceCacheTests: fix the swift format lint findings already at HEAD'
---
Found while working ^vapqv96. `swift format lint -s Tests/MarketplaceTests/MarketplaceCacheTests.swift` reports 13 findings that are already present at HEAD (827bdae), none of them from ^vapqv96: one `[AddLines] add 1 line break` (in `stageSnapshot(sha:)`, the `let staged = root` chain) and 12 `[LineLength] line is too long` (the `install(through:snapshotAt:sha:ref:)` signature, the `destinationOfSymbolicLink` line, the telemetry tests' `cacheCounts`/`Array(repeating:)` lines, the `withSnapshotInUse` capture line, the two unsafe sha/ref test signatures and their bodies, and the `writerLockHeld` row of `cacheErrorDescriptions`).

## Subtasks
- [ ] Reflow each reported line so `swift format lint -s Tests/MarketplaceTests/MarketplaceCacheTests.swift` exits 0
- [ ] `swift test` passes, zero warnings