---
comments:
- actor: claude-code
  id: 01m2xm6dsq7cj04z2nx6akf3n0
  text: |-
    Picked up. Research findings:

    - The three Skills sources are in `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/`: `MarketplaceCache.swift` (874 lines: `MarketplacePathValue`, `MarketplaceCacheError`, `MarketplaceCache`, `SnapshotLease`), `MarketplaceState.swift` (`MarketplacePendingSnapshot`, `MarketplaceStateRecord`, `MarketplaceState`) and `SnapshotWriter.swift` (`SnapshotLimits`, `SnapshotError`, `SnapshotReport`, `SnapshotWriter`, the private `SnapshotRun`). All with 4-space indentation. Every type is `internal`, except `SnapshotLimits`, which is `public`.
    - `SnapshotLimits` is already in `Sources/Marketplace/SnapshotLimits.swift` (card ^vms0qv0 decision 1), byte for byte the Skills type with 2-space indentation. This card does not add a second copy.
    - The Skills `SnapshotWriter` holds `static let partialsDirectoryName = "_partials"` and `SnapshotRun.copyPartials` reads it. `MarketplaceLayout.partialsDirectoryName` exists here with the default `"_partials"`, and its doc comment says the snapshot writer reads it. `SnapshotWriter.write(catalog:from:to:limits:)` has no layout parameter in Skills.
    - The moved code names `CatalogPath.child(named:of:)`, `CatalogPath.separator`, `CatalogPath.display(path:)`, `CatalogFileSource`, `CatalogTreeEntry`, `ResolvedCatalog`, `ResolvedSkill`, `MarketplaceDiagnostic`, `MarketplaceIdentity.cacheFolderName(key:normalizedURL:)`. All exist here with the same shape.
    - The Skills doc comments that this card changes: `sharedLock(onDirectory:)` says "no extra file that skill discovery would see"; `noInheritanceOpenFlags` says "A marketplace skill can run a script or a shell command under the host `RenderPolicy`"; `currentLinkName` and `currentLink` say "the snapshot the registry reads".
    - `MarketplaceState` doc comments hold DocC links to `MarketplaceStore/start()`, `MarketplaceStore/pin(_:sha:)`, `MarketplaceStore/unpin(_:)` and `MarketplacePolicy/ApplyUpdates/nextLaunch`. The store comes with card ^qtwjzx9. Card ^vms0qv0 decision 5 keeps such links.
    - The Skills tests: `MarketplaceCacheTests.swift` (564 lines) calls `MarketplaceTestSupport.makeTempDirectory()` with no files, `MarketplaceTestSupport.writeFile(text:to:)`, `SnapshotLockProbe.isLocked(directory:)` and `OpenDescriptorProbe.descriptorFlags(ofOpensAt:)`. `SnapshotWriterTests.swift` (394 lines) calls `FixtureLibrary.marketplaceCatalog(named:)`, `CatalogResolver.resolve(from:selection:)` with no layout, `MarketplaceTestSupport.makeTempDirectory(withFiles:)`, and `SkillsRegistry(roots:)` in its happy path to prove that the snapshot loads as a layer root. This package has no `SkillsRegistry`.
    - The two probes are in the Skills `MarketplaceTestSupport.swift`. `OpenDescriptorProbe` reads `proc_pidinfo(PROC_PIDLISTFDS)` and `fcntl(F_GETPATH)`; its comments name `RunScriptTests`, `ShellInjectionTests` and `MarketplaceStoreTests`, which are Skills suites.
    - This package: `Tests/MarketplaceTests/MarketplaceTestSupport.swift` has `skillsLayout`, `catalogFixture(named:)`, `makeTempDirectory(withFiles:)` (no default) and `writeFile(text:to:)`. `FixtureSupport.TemporaryDirectory.make()` makes an empty folder. The `swissarmyhammer-skills` fixture catalog is under `Tests/MarketplaceTests/Fixtures/catalogs/` with `skills/_partials/sah-task-standards.md` and the `writing-good-tests.md` of `tdd`: five files.
    - The review rules file for `.swift` holds 60 rules over 7 validators; a subagent digest is in progress.
  timestamp: 2026-09-19T20:02:19.575692+00:00
- actor: claude-code
  id: 01m2xmrdae9csnjnjz5pfg0t17
  text: |-
    Decisions:

    1. `SnapshotLimits` stays in `Sources/Marketplace/SnapshotLimits.swift`, where card ^vms0qv0 put it. `SnapshotWriter.swift` holds `SnapshotError`, `SnapshotReport`, `SnapshotWriter` and the private `SnapshotRun`. The card lists `SnapshotLimits` under `SnapshotWriter.swift`; a second copy or a move of an existing file would be a change with no reason.
    2. `SnapshotWriter.write(catalog:from:to:layout:limits:)` takes the `MarketplaceLayout` as a parameter, before `limits`. The Skills static `SnapshotWriter.partialsDirectoryName` is removed; the private `SnapshotRun` holds `partialsDirectoryName` from `layout.partialsDirectoryName`. `largeFileStoragePrefix` stays a static of the writer, because the test reads it. The path safety rules, the limits and the execute bit do not change.
    3. Doc comment wording in `MarketplaceCache`: `sharedLock(onDirectory:)` says "no extra file that a reader of the layer root would see" (was "skill discovery"). The `noInheritanceOpenFlags` comment says "The host can start a child process at any moment." in place of the sentence that named `RenderPolicy`; the `O_CLOEXEC` and `O_CLOFORK` rule and its reasons stay. `currentLinkName` and `currentLink` say "the snapshot the consumer reads" (was "the registry"), the wording of card ^vms0qv0. The `cacheDirectory(environment:)` doc no longer names `ModelResolver.hubCacheDirectory(environment:)`, a Skills type; the sentence that follows it describes the same rule.
    4. Access levels stay as in Skills: every moved type is `internal`, and `SnapshotLimits` is `public`. The tests reach them with `@testable import Marketplace`, and `MarketplaceTestSupport.swift` now imports `Marketplace` with `@testable` too, because `SnapshotLockProbe` reads `MarketplaceCache.noInheritanceOpenFlags`.
    5. `MarketplaceState` keeps its DocC links to `MarketplaceStore/start()`, `MarketplaceStore/pin(_:sha:)`, `MarketplaceStore/unpin(_:)` and `MarketplacePolicy/ApplyUpdates/nextLaunch` (card ^vms0qv0 decision 5). Card ^qtwjzx9 brings the store.
    6. The env variable names `SKILLS_MARKETPLACE_CACHE` and `SKILLS_MARKETPLACE_SEED` and the default path `.cache/skills/marketplaces` move with `MarketplaceCache` as they are (card ^vms0qv0 decision 3).
    7. Tests: `MarketplaceCacheTests` uses `TemporaryDirectory.make()` in place of the Skills `makeTempDirectory()`. `SnapshotWriterTests` uses `MarketplaceTestSupport.catalogFixture(named:)` and the `skillsLayout`. The Skills happy path proved the layer root with `SkillsRegistry(roots:)`, which is not here; the test now reads the folder names of the root (`_partials`, `code-context`, `commit`, `tdd`) and checks that each entry folder holds `SKILL.md`. One shared helper `writeSnapshot(ofFolder:selection:layout:limits:to:)` serves the fixture write and the temporary-tree write, so the two are not a near-copy.
    8. New tests beyond the moved ones. Cache: the seed variable and its absence; `current` is a symlink to `snapshots/<sha>`; stage then adopt, and adopt of a missing snapshot; a second writer lock is refused at once, and the lock is free after the body; the asynchronous writer lock holds across a suspension; `installUnderWriterLock` for a caller that holds the lock (the last two have no other caller in this package until the store card, and an `internal` member with no caller is dead code under `dead-code-swift`); an uppercase sha is a commit; the description of each cache error; the state round trip with a pending snapshot and `unpinned`; a `{}` state file decodes to the empty state. Writer: the partials folder takes the name of the layout (`_shared`), with a `_partials` folder in the tree that is not copied; each entry folder holds its document; a plain file gets no execute bit; the unsafe names `..`, `a..b`, `.`, `a/b`, `a\b`, empty and a tab, and the symlink targets `../../outside.md`, `../outside.md`, `/etc/passwd`, `~/secret`, `sub/../../outside.md` are parameterized; the report counts a symbolic link as one file with no bytes; the description of each snapshot error.
    9. The two probes `SnapshotLockProbe` and `OpenDescriptorProbe` are in `Tests/MarketplaceTests/MarketplaceTestSupport.swift` as in Skills. Their comments no longer name `RunScriptTests`, `ShellInjectionTests` or `MarketplaceStoreTests`, which are Skills suites.
    10. Numeric literals in the tests are named statics (`oneFileAndOneLink`, `limitOfOne`, `executablePermissions`), because `magic-numbers-swift` reads a Swift Testing suite the same as production code. The error description tables are typed statics `[(error: E, text: String)]`, so each tuple element has a type.

    TDD: RED was `swift build --build-tests` with the test files and the test support in place and no moved source: `cannot find 'MarketplaceCache' in scope` (exit 1). GREEN is the three source files.
  timestamp: 2026-09-19T20:12:08.910741+00:00
- actor: claude-code
  id: 01m2xn2cd63frngma9xwxkbbwb
  text: |-
    Implementation landed. Notes for the next agent:

    - TDD cycle: RED was `swift build --build-tests` with the two test files, the probes in `MarketplaceTestSupport.swift` and no moved source; the compiler stopped with `cannot find 'MarketplaceCache' in scope` (exit 1). GREEN was the three source files; the same build completes with no `warning:` line. `swift test --filter "MarketplaceCacheTests|SnapshotWriterTests"` passes 62 tests in 2 suites. The full `swift test` passes 6 bundles (125 + 34 + 44 + 26 + 256 + 367 = 852 tests), 0 failures, 0 skipped. `MarketplaceTests` went from 194 tests in 14 suites to 256 tests in 16 suites.
    - The three tools that the review runs were run here first, on the six changed files. `swiftlint` with the rule set of the validators (`no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]`, `missing_docs`, the force rules, the length rules): 0 findings. `swift-format lint` with the seven-rule allowlist of `idioms-swift`: 0 findings. `periphery scan --retain-public --skip-build --index-store-path .build/out`: one row, `var.parameter isolation` on the asynchronous `withWriterLock`, which the `dead-code-swift` rule drops.
    - The first periphery run reported eight `assignOnlyProperty` rows: `MarketplacePendingSnapshot.sha`, `.catalogVersion`, `.displayID`, and `MarketplaceStateRecord.url`, `.unpinned`, `.pending`, `.displayID`, `.lastUpdated`. In this module only the synthesized `Codable` and `Hashable` read them; the store of card ^qtwjzx9 reads them in Skills. The fix is not the marker: the decode test `aStateFileWithEveryFieldDecodesEachField` (the Skills `theDocumentedStateFileDecodes`, with `unpinned`, `pending` and `displayID` added to the file) reads each field, so the decode of each field is proven and each property has a caller. The two dates of that file are named `TimeInterval` statics whose values `date -u -j` gave (`1_789_415_743`, `1_789_200_600`).
    - One compiler warning was corrected before GREEN: a single-expression closure that ended in `#expect(throws:)` returned the caught error to `withWriterLock`, thus `result of call to 'withWriterLock' is unused`. The test now binds the caught error and asserts on it.
    - The moved code is the Skills code with 2-space indentation and the changes of the decisions comment: the `layout` parameter of `SnapshotWriter.write`, the removed `partialsDirectoryName` static, and the four doc comment sentences. Nothing else in the three files changed. A grep over `Sources/Marketplace` for `skill discovery`, `RenderPolicy`, `registry`, `ModelResolver`, `grant`, `SkillsRegistry` and `FixtureLibrary` finds nothing.
    - The `FoundationModelsSkills` working tree shows no change under its `Marketplace` sources or tests from this card: this card read that repository only.
    - Card text against the source, for the reviewer: the card lists `SnapshotLimits` under `SnapshotWriter.swift`. It is in `Sources/Marketplace/SnapshotLimits.swift` since card ^vms0qv0, and this card did not add a second copy (decision 1).
  timestamp: 2026-09-19T20:17:35.654897+00:00
- actor: claude-code
  id: 01m2xn2g34kdwjwwsxbhr0c3d7
  text: |-
    ### implement — changed
    - evidence: 6 files. Modified: Tests/MarketplaceTests/MarketplaceTestSupport.swift. Added: Sources/Marketplace/MarketplaceCache.swift, Sources/Marketplace/MarketplaceState.swift, Sources/Marketplace/SnapshotWriter.swift, Tests/MarketplaceTests/MarketplaceCacheTests.swift, Tests/MarketplaceTests/SnapshotWriterTests.swift. RED: `swift build --build-tests` failed with `cannot find 'MarketplaceCache' in scope` (exit 1). GREEN: `swift build --build-tests` exit 0, 0 warnings; `swift test` 852 tests in 6 bundles pass, 0 failures, 0 skipped (MarketplaceTests: 256 tests in 16 suites). swiftlint 0, swift-format 0, periphery 0 rows after the dropped `var.parameter` row. No change in `FoundationModelsSkills`.
    - next: `/review` moves the card into review.
  timestamp: 2026-09-19T20:17:39.428287+00:00
- actor: claude-code
  id: 01m2xn97g6jxvm5j6b2b6ctpry
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` — 0 warnings, 0 errors; `swift test` — 367 tests in 30 suites passed, 0 failed, 0 skipped (includes the new "Marketplace cache" and "Marketplace snapshot writer" suites)
    - next: hand off to review.
  timestamp: 2026-09-19T20:21:20.006187+00:00
- actor: claude-code
  id: 01m2xnbbz45xg7rgawzqx5ycq4
  text: |-
    ### commit — changed
    - evidence: 7c3146d feat(marketplace): move the cache, the state file, and the snapshot writer
    - next: the review step can start.
  timestamp: 2026-09-19T20:22:30.116431+00:00
- actor: claude-code
  id: 01m2xnmpfh4dapsbwvak454e9k
  text: |-
    ### review — clean
    - evidence: 0 findings. Scope `review sha HEAD~1..HEAD` (commit 7c3146d). 6 files reviewed, 14 validator runs attempted, 0 failed. 4 files under `.kanban/` were not reviewed because of `.reviewignore`. No prior review findings section is on the task.
    - next: The task is in `done`. No more work is necessary on this task.
  timestamp: 2026-09-19T20:27:35.793636+00:00
- actor: claude-code
  id: 01m2xnn5nb0pgx1n9qxcr7hcr5
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files
    - test: green — swift test, 852 passed in 6 bundles, 0 failed, 0 skipped
    - commit: 7c3146d
    - review: clean — 0 findings, task moved to done
  timestamp: 2026-09-19T20:27:51.339894+00:00
depends_on:
- 01M2XDHD4KZ7E1WWRD0VMS0QV0
- 01M2XDHD6WSMB5PQ0707Z1W5F8
position_column: done
position_ordinal: ad80
title: Move the cache, the state file and the snapshot writer
---
## What

In the `Marketplace` target, move the part that writes a layer root to disk: the cache layout under the cache directory, the `state.json` record, the snapshot lease and lock, and the writer that materializes the selected entries of a commit into a flat snapshot.

1. Move these files from `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/` into `Sources/Marketplace/`, with 2-space indentation and the same type names: `MarketplaceCache.swift` (`MarketplaceCache`, `MarketplaceCacheError`, `MarketplacePathValue`, `SnapshotLease`), `MarketplaceState.swift` (`MarketplaceState`, `MarketplaceStateRecord`, `MarketplacePendingSnapshot`), `SnapshotWriter.swift` (`SnapshotWriter`, `SnapshotLimits`, `SnapshotError`, `SnapshotReport`).
2. `SnapshotWriter` reads its partials directory name from the `MarketplaceLayout` value that the catalog card added (`partialsDirectoryName`), not from a constant. The path safety rules do not change: no `..`, no separator, no control character in an entry name; a symlink stays inside its own entry folder; a submodule is refused; the size and count limits of `SnapshotLimits` apply. The execute bit of a `100755` blob is kept.
3. `MarketplaceCache` keeps its doc comments about the lock on the folder, but the sentence that names "skill discovery" changes to "a reader of the layer root". The `O_CLOEXEC` and `O_CLOFORK` rule stays, and its comment no longer names a grant.
4. Move the tests `MarketplaceCacheTests.swift` and `SnapshotWriterTests.swift` into `Tests/MarketplaceTests/`, and the probes `SnapshotLockProbe` and `OpenDescriptorProbe` of the Skills `MarketplaceTestSupport` into `Tests/MarketplaceTests/MarketplaceTestSupport.swift`. The happy path of the writer test uses the `swissarmyhammer-skills` fixture catalog over `LocalCatalogFileSource`; the rejection cases use the in-memory `CatalogFileSource` that the test file defines.
5. Do not delete anything in `FoundationModelsSkills`.

## Acceptance Criteria

- [ ] The cache layout is the one of the Skills `marketplace.md` §7.2: `<cache>/<folder>/repo.git`, `refs/`, `snapshots/<sha>/`, `current` as a symlink, `state.json`, and the lock on the folder.
- [ ] The `current` swap is one `rename(2)` of a new symlink over the old one, and cleanup keeps the two newest snapshots plus the pinned one.
- [ ] `SnapshotWriter` writes a flat root of `<entry>/` folders plus the partials folder named by the layout, refuses each unsafe entry, and keeps the execute bit.
- [ ] `state.json` loads back equal after a save, with the pending snapshot record.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/MarketplaceTests/MarketplaceCacheTests.swift`: the location from the environment variable and the default; the folder layout; the atomic `current` swap; cleanup by count; the state file round trip; the lease holds `flock` and the descriptor has `FD_CLOEXEC` and `FD_CLOFORK`.
- [ ] `Tests/MarketplaceTests/SnapshotWriterTests.swift`: the flat layout with the partials folder from the layout value; the execute bit; a symlink that leaves its entry folder, a submodule, and an unsafe name are each refused with the named error; the size and count limits give a report.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail. #marketplace #cross-repo