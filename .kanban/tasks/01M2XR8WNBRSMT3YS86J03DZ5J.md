---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2xw2jj1cpew41ew5r7ypp6h
  text: |-
    Research done. The readers of the three types, traced in the two files:

    - `Diagnosed<Value>` in `CatalogResolver.swift`: the sibling `CatalogReader` reads it in each step, and the `extension Array` in the same file reads it in `collected()`. It is not dead code.
    - `CatalogReader` in `CatalogResolver.swift`: the sibling `CatalogResolver` reads it in `resolve(from:selection:layout:)`. It is not dead code.
    - `SnapshotRun` in `SnapshotWriter.swift`: the sibling `SnapshotWriter` reads it in `write(catalog:from:to:layout:limits:)`. It is not dead code.

    Thus each type becomes `fileprivate struct`. No type goes away.

    The doc comment sentence follows `MarketplaceStore.swift`: "The store reads it, thus it is `fileprivate` and not `private`." on `Preparation`.

    Rules: the `swift/access-control` rule (Swift Access Control) says `fileprivate` is correct when a sibling type in the same file reads the type. I read the Swift rule set of the validator dump whole, and the Swift documentation rules. The other rule sets in the dump apply to code shapes that this change does not touch.

    Decision: the nested `private enum CatalogRead` in `CatalogResolver` stays `private`. Only `CatalogResolver` reads it, and the card says to change no other access level.
  timestamp: 2026-09-19T22:20:01.985612+00:00
- actor: claude-code
  id: 01m2xw600epj1qn3fzt76ywszt
  text: |-
    Implementation landed. Decisions:

    - TDD: the change is an access level change with no behavior change. A test target reaches `internal` through `@testable import`, and it never sees `private` or `fileprivate`, thus no unit test can go red on this change. The existing suite is the guard, as the card and the caller say. No new test.
    - `Diagnosed<Value>` has two readers in its file: `CatalogReader` and the `Array` extension. The doc sentence names both: "``CatalogReader`` and the `Array` extension read it, thus it is `fileprivate` and not `private`."
    - `CatalogReader`: "``CatalogResolver`` reads it, thus it is `fileprivate` and not `private`."
    - `SnapshotRun`: "``SnapshotWriter`` reads it, thus it is `fileprivate` and not `private`."
    - The doc sentence uses the DocC form ``Type`` for the reader, as `MarketplaceStore.swift` does on `localSkillsFolderName`.
    - The nested `private enum CatalogRead` stays `private`: only `CatalogResolver` reads it, and it is not top-level.

    Evidence:

    - `swift build --build-tests`: exit 0, 0 warnings, 0 errors.
    - `swift test`: exit 0, all runs green, 375 tests in 30 suites in the last run, 0 failures, 0 skipped.
    - `rg '^private (struct|enum|class|final class|actor|protocol)' Sources/Marketplace`: no match.
    - `git diff --stat -- Sources`: 2 files changed, 10 insertions, 3 deletions.
  timestamp: 2026-09-19T22:21:54.062721+00:00
- actor: claude-code
  id: 01m2xw61kc5x16z9x2vadcw52r
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/Marketplace/CatalogResolver.swift, Sources/Marketplace/SnapshotWriter.swift; `swift build --build-tests` 0 warnings; `swift test` 375 tests, 0 failures
    - next: /review
  timestamp: 2026-09-19T22:21:55.692828+00:00
- actor: claude-code
  id: 01m2xwa0w27a9vrsy4fgbftz4m
  text: |-
    ### test — green
    - evidence: swift build --build-tests (0 warnings, exit 0); swift test — 375 tests, 30 suites, 0 failed, 0 skipped, 0 warnings
    - next: send the task to review.
  timestamp: 2026-09-19T22:24:06.018496+00:00
- actor: claude-code
  id: 01m2xwase4mf0yktxees14n02e
  text: |-
    ### commit — changed
    - evidence: a2e7fc0 fix(marketplace): change private types to fileprivate in CatalogResolver and SnapshotWriter
    - next: none
  timestamp: 2026-09-19T22:24:31.172976+00:00
- actor: claude-code
  id: 01m2xwfd5v5vpk8hqv3xmah11g
  text: |-
    ### review — clean
    - evidence: 0 findings — `review sha HEAD~1..HEAD` (a2e7fc0), 2 files reviewed, 1 candidate refuted, no prior findings open
    - next: none. The task is in `done`.
  timestamp: 2026-09-19T22:27:02.459917+00:00
- actor: claude-code
  id: 01m2xwg2qxs7qqrnyw6tjfp1az
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files
    - test: green — swift test, 375 passed in 30 suites, 0 failed, 0 skipped
    - commit: a2e7fc0
    - review: clean — 0 findings, task moved to done
  timestamp: 2026-09-19T22:27:24.541250+00:00
position_column: done
position_ordinal: b280
title: Make the top-level private types of CatalogResolver.swift and SnapshotWriter.swift fileprivate
---
## What

The `swift/access-control` rule says: `fileprivate` is required when a sibling type in the same file reads a type; `private` reaches only the same declaration and same-file extensions of that exact type. The review of card ^qtwjzx9 found this cause on `Preparation` in `Sources/Marketplace/MarketplaceStore.swift`, and that card corrected only its own file. The same cause is in two other files of the target:

- `Sources/Marketplace/CatalogResolver.swift`: `private struct Diagnosed<Value>` and `private struct CatalogReader`
- `Sources/Marketplace/SnapshotWriter.swift`: `private struct SnapshotRun`

For each type:

1. Trace the reader. A sibling type in the same file reads it, thus it becomes `fileprivate struct`. A type that no sibling reads is dead code, and it goes away.
2. Add the sentence of the file convention to its doc comment, as `MarketplaceStore.swift` does: "The <reader> reads it, thus it is `fileprivate` and not `private`."

Do not change any other access level. Do not change behavior.

## Acceptance Criteria

- [x] No top-level type under `Sources/Marketplace` is `private`.
- [x] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [x] `swift test` — all tests pass, 0 failures.

#marketplace