---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5jaskbn68eb8zfxkxgq4k9d
  text: |-
    Picked up. Research: the repo has no .swift-format file, so the defaults apply (lineLength 100, indentation 2 spaces), and the file already uses 2-space indentation. `swift format format` run on a scratch copy changed only the 13 flagged hunks, so its output was applied as is: the `let staged =` / `root` break, long signatures wrapped as `...)` / `  [async] throws` / `{` (the same wrapping SlashCommandTests, CorpusGoldenTests and SnapshotWriter already use), one-line `Result { ... }` and `#expect(...) { try installed.get() }` closures opened onto three lines, overlong argument lists wrapped, and the `writerLockHeld` row of `cacheErrorDescriptions` turned into a multi-line tuple like the `cannotSwap` row. Code tokens are unchanged, so test behavior is unchanged.

    Discovery: `swift test` prints one build-system warning, `warning: missing creator for mutated node: ('.../.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`. It comes from the SwiftPM build graph for the mlx-swift resource bundle, not from this test file. Filed as new task 01M5JAS43FR3JVS3515VP7EJME.
  timestamp: 2026-10-22T17:33:28.821981+00:00
- actor: claude-code
  id: 01m5jasng98fjwdz62xvav399b
  text: |-
    ### implement — changed
    - evidence: Tests/MarketplaceTests/MarketplaceCacheTests.swift; `swift format lint -s` went from 13 findings (1 AddLines, 12 LineLength, exit 1) to 0 (exit 0); `swift test`: 1557 tests in 160 suites passed, 0 failures; the one SwiftPM build warning about the mlx bundle is outside this file and is filed as 01M5JAS43FR3JVS3515VP7EJME
    - next: /review
  timestamp: 2026-10-22T17:33:31.017416+00:00
- actor: claude-code
  id: 01m5jav8e4nz77c0dqfnhmqcw4
  text: |-
    ### test — green
    - evidence: swift test — 1557 tests in 160 suites passed, 0 failed, 0 skipped; swift format lint -s Tests/MarketplaceTests/MarketplaceCacheTests.swift — exit 0, no findings
    - note: SwiftPM warning "missing creator for mutated node" on mlx-swift_Cmlx.bundle/Contents/MacOS is tracked on ^vp7ejme; not addressed here. No other warnings.
    - next: review / commit
  timestamp: 2026-10-22T17:34:23.172175+00:00
- actor: claude-code
  id: 01m5javt9vrg3q5gzbqpme601x
  text: |-
    ### commit — changed
    - evidence: single local commit of MarketplaceCacheTests.swift line wrapping plus all .kanban changes (including new card ^vp7ejme); not pushed
    - next: review
  timestamp: 2026-10-22T17:34:41.467403+00:00
position_column: doing
position_ordinal: '80'
title: 'MarketplaceCacheTests: fix the swift format lint findings already at HEAD'
---
Found while working ^vapqv96. `swift format lint -s Tests/MarketplaceTests/MarketplaceCacheTests.swift` reports 13 findings that are already present at HEAD (827bdae), none of them from ^vapqv96: one `[AddLines] add 1 line break` (in `stageSnapshot(sha:)`, the `let staged = root` chain) and 12 `[LineLength] line is too long` (the `install(through:snapshotAt:sha:ref:)` signature, the `destinationOfSymbolicLink` line, the telemetry tests' `cacheCounts`/`Array(repeating:)` lines, the `withSnapshotInUse` capture line, the two unsafe sha/ref test signatures and their bodies, and the `writerLockHeld` row of `cacheErrorDescriptions`).

## Subtasks
- [x] Reflow each reported line so `swift format lint -s Tests/MarketplaceTests/MarketplaceCacheTests.swift` exits 0
- [x] `swift test` passes, zero warnings