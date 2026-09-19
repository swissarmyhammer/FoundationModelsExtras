---
comments:
- actor: claude-code
  id: 01m2xnnpefbxtppxwa5cjryhyk
  text: |-
    ### finish — note on item 7
    - The finish loop commits a local checkpoint on each iteration and never pushes. The push to `main` is the step of the user after the loop.
    - The work of the four cards before this one is in local commits 8ca12e2, 70f75d4, 81c51f8, 9a7774a, 6ab7281 and 7c3146d.
    - next: the user pushes `main` after this card is in `done`.
  timestamp: 2026-09-19T20:28:08.527700+00:00
- actor: claude-code
  id: 01m2xnzh2tf258rv0ppbtcetqs
  text: |-
    Picked up. Research findings:

    - The Skills sources to move are in `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/`: `MarketplaceStore.swift` (1,575 lines: the actor, the private `Preparation` struct), `MarketplaceEvent.swift`, `MarketplaceStatus.swift`, and `MarketplaceLayerProviding.swift` (`MarketplaceProvenance`, `MarketplaceLayer`, the protocol, and `MarketplaceProvenanceIndex`, which stays). All with 4-space indentation. `MarketplaceLayer` has no `grants` field in Skills now.
    - `MarketplaceDiagnostic.swift` is already here (card ^vms0qv0), byte for byte the Skills type. This card adds no second copy.
    - The store names `EventBroadcaster<Element>`, an `internal final class` in the Skills `Registry/EventBroadcaster.swift`, outside the marketplace folder. This package has no equivalent (no `AsyncStream.makeStream` and no `subscribe()` under `Sources/`). Without it the store does not build. Its doc comment names `SkillsRegistry`. Its `finishAll()` has no caller in the store; only the Skills registry calls it.
    - The store calls `CatalogResolver.resolve(from:selection:)` and `SnapshotWriter.write(catalog:from:to:limits:)` in Skills. Here both take a `layout:` parameter (cards ^7z1w5f8 and ^nqdcd57). Every other symbol the store names exists here with the same shape: `MarketplaceCache` (`seedDirectory(environment:)`, `stateFile(inCacheDirectory:)`, `validated(sha:)`, `currentSha()`, `currentLink`, `folderName`, `repositoryDirectory`, `snapshotsDirectory`, `makeFolders()`, `withWriterLock` sync and async, `installUnderWriterLock`, `stageUnderWriterLock`, `adopt(snapshotSha:ref:)`, `leaseCurrentSnapshot()`), `SnapshotLease.releaseNow()`, `MarketplaceState`, `MarketplaceStateRecord`, `MarketplacePendingSnapshot`, `MarketplaceIdentity`, `MarketplaceLocation`, `MarketplacePolicy.refusal(forNormalizedURL:)` and `SourceRefusal`, `MarketplacePinError`, `GitTreeFileSource`, `GitTransport`, `LibGit2Transport` (public), `MarketplaceTimeoutError`, `CatalogPath.normalized(path:)`, `DotfolderStack.Layer(source:root:)` (public in the core target).
    - The Skills tests: `MarketplaceStoreTests` (250 lines), `MarketplaceUpdateTests` (311), `MarketplacePinTests` (416), `MarketplacePolicyTests` (167), `MarketplaceLocalSourceTests` (241). Six tests assert through `SkillsRegistry` (`makeRegistry().call(id:)`, `registry.onReload`, `FakeMarketplaceProvider`): the two cold-start reload tests and the two watcher tests stay in Skills; the four that only read a skill body through the registry become a read of `<layer root>/alpha/SKILL.md` here.
    - The Skills test support that the moved tests call: `MarketplaceTestSupport.skillTree(body:)` and `fixtureSkillID` (in `MarketplaceTestSupport.swift`), `ReloadTestSupport.skillFileContents(id:body:)` and `writeSkillFile(id:in:body:)` (a `SKILL.md` with `name` and `description` frontmatter), `WatcherTestSupport.makeTempDirectory()`. Here: `TemporaryDirectory.make()` in `FixtureSupport`, `MarketplaceTestSupport.writeFile(text:to:)` and `makeTempDirectory(withFiles:)`, `SnapshotLockProbe` (already moved with card ^nqdcd57).
    - `RecordingGitTransport` is already public in `MarketplaceFixtures` (card ^jhj8kd2). `GitFixtureRepository` has `commit(files:)` over `[String: Entry]` and `url`.
    - `MarketplaceFixtures` depends on `Marketplace` without `@testable`, thus `MarketplaceStoreFixture` there can call only a public store init. That is the reason of card item 3: the init with `transport:` and `clock:` becomes public.
    - `MarketplaceProvenanceDisplayTests` in Skills asserts through `SkillsRegistry` and `SkillsTool`, thus it stays. `MarketplaceProvenance.displayText` then has no test here.
    - `Package.swift`: `MarketplaceFixtures` already depends on `Marketplace`, `FixtureSupport` and `libgit2`; `MarketplaceTests` on all three. No manifest dependency change is necessary.
    - The review rules file for `.swift` holds 60 rules over 7 validators; a subagent digest is in progress.
  timestamp: 2026-09-19T20:33:30.714735+00:00
- actor: claude-code
  id: 01m2xq8c7cj5wppgjthyzn851n
  text: |-
    Decisions:

    1. `EventBroadcaster` moves into `Sources/Marketplace/EventBroadcaster.swift` as an `internal final class`, the same rule as card ^jhj8kd2 decision 1: the store names it, thus the target does not build without it. Its `finishAll()` is not moved: the store never calls it, and an internal member with no caller is dead under `dead-code-swift`. It gets an internal `subscriberCount`, which `EventBroadcasterTests` reads to prove that a dropped subscriber keeps no slot. Its doc comment names the store and not `SkillsRegistry`.
    2. `MarketplaceStore.init(sources:layout:cacheDirectory:policy:)` and `init(sources:layout:cacheDirectory:policy:transport:clock:environment:)` take the `MarketplaceLayout` after `sources:`. The store keeps it in a private `layout` property and passes it to `CatalogResolver.resolve(from:selection:layout:)` and `SnapshotWriter.write(catalog:from:to:layout:limits:)` in `materialize`. `localSkillsFolderName` stays a `fileprivate static` of the store. The second init is `public`; `environment` keeps its default.
    3. Doc comment wording: every sentence that named `SkillsRegistry` or "the registry" now says "the consumer". The code example in the store doc shows the `layout:` argument and `marketplaceLayers()` in place of a registry. The `servedFromDisk` doc says that a consumer takes the root of each layer when it is built. `MarketplaceEvent.updated` says "The consumer reads the layers again." The `MarketplaceLayerProviding` doc is the sentence of the card. A grep over `Sources/Marketplace` for `registry` finds nothing.
    4. `MarketplaceLayerProviding.swift` holds `MarketplaceProvenance`, `MarketplaceLayer` and the protocol. `MarketplaceProvenanceIndex` stays in Skills, as the card orders.
    5. `MarketplaceStoreFixture` (public, in `Tests/MarketplaceFixtures/`) has no `makeRegistry`, and keeps `cacheDirectory`, `localRoot` and `store` as the card lists them. Its init takes `layout:` after `sources:` with the default `MarketplaceStoreFixture.skillsLayout` (`SKILL.md`), because every fixture repository of this package and of the Skills tests has that layout; the Skills tests that stay behind then build a store with no change of their call.
    6. `ManualClock`, `GatedGitTransport`, `MarketplaceEventLog` and `TestSignal` are public types in `MarketplaceFixtures` with a public `init()` and public members. `ManualClock.Instant` gets a public `init(sinceStart:)`, because the memberwise init of a public struct is internal.
    7. The moved tests that read a skill through `SkillsRegistry` now read `<layer root>/alpha/SKILL.md` through `MarketplaceTestSupport.skillBody(inLayerRoot:)`, as a consumer does. The two `onReload` tests and the two watcher tests stay in Skills. The `layerUpdates` proof is `eachSwapPublishesOneLayerUpdateAndACheckPublishesNone`: a tally task counts the values over a cold start, a check, an update with no change and an update with a new commit, waits for two values, then waits one settle window of 500 ms and expects exactly two. That window is the one real-time wait of the suites, as the Skills store suite had with 1 s; the update suite waits on no real time.
    8. The Skills test `anUnreachableURLKeepsTheLastGoodSnapshot` deleted the fixture repository between two stores. Here it found a latent behavior: `MarketplaceLocation.localFolder` normalizes with `standardizedFileURL`, which removes the `/private` prefix only for a path that exists, thus the two stores hashed different normalized URLs and read different cache folders (`fixture-7f75ef83` and `fixture-81899733`). In Skills the temporary folder was not canonical, thus both forms agreed. The test is now `anUnreachableRemoteKeepsTheLastGoodSnapshot`: a private `UnreachableGitTransport` double throws `GitTransportError.unreachable` before any libgit2 work, thus the URL and the cache folder stay the same. The latent behavior is task ^wbtvy0p, outside this card.
    9. The two local-folder tests compare `layer.layer.root.canonicalDirectory` with the folder, because `TemporaryDirectory.make()` gives the `/private/var` form and the store gives the `/var` form of the same folder.
    10. New tests beyond the moved ones: `theDefaultInitReadsTheSnapshotThatAnEarlierStoreInstalled` (the public init with no transport), `aColdStartGivesALayerWithTheStableCurrentRootAndTheProvenance` and `theLayersComeInListOrderLowestFirst` (the second acceptance criterion), `nextLaunchWritesThePendingSnapshotIntoTheStateFile` and the `pending == nil` check after the swap (the pin test list of the card), `aLocalFolderSourceGivesItsLayerBeforeStart`, `aPathThatLeavesTheLocalFolderGivesNoLayerAndAnError`, `MarketplaceProvenanceTests` (the `displayText` of a public type, which the Skills display tests prove only through the registry), `EventBroadcasterTests`, and `ModuleBoundaryTests` with one test for the four type names and one for `import FoundationModelsSkills`.
    11. `keptVersion(ofFirst:)` is one helper in `MarketplaceTestSupport`, because the store suite and the update suite both read it and a copy in each file is a duplicate under `duplication`. `skillTree(body:)`, `skillDocument(named:body:)`, `writeSkillFolder(named:in:body:)`, `fixtureSkillID` and `skillsFolderName` are there for the same reason.
    12. `MarketplaceUpdateTests` reads `MarketplacePolicy.automaticUpdateVariable` in place of the literal `SKILLS_MARKETPLACE_AUTOUPDATE`. `aPinThatIsNoCommitThrows` expects the typed `MarketplaceCacheError.notACommit(value:)` in place of `(any Error).self`.
    13. `Package.swift` changes only the comment of the `MarketplaceFixtures` target, which now names the five doubles. No dependency changes.

    TDD: RED was `swift build --build-tests` with the five doubles, the test support and the eight test files in place and no moved source: `cannot find type 'MarketplaceEvent' in scope` (exit 1). GREEN is the five source files.
  timestamp: 2026-09-19T20:55:49.228031+00:00
- actor: claude-code
  id: 01m2xqah19pv3ch8w6yty8bex4
  text: |-
    Implementation landed. Notes for the next agent:

    - TDD cycle: RED was `swift build --build-tests` with the five doubles in `Tests/MarketplaceFixtures/`, the changed `MarketplaceTestSupport.swift` and the eight test files in place, and no moved source; the compiler stopped with `cannot find type 'MarketplaceEvent' in scope` (exit 1). GREEN was the five source files; the same build completes with no `warning:` line. The full `swift test` passes 6 bundles (125 + 34 + 44 + 26 + 325 + 367 = 921 tests), 0 failures, 0 skipped. `MarketplaceTests` went from 256 tests in 16 suites to 325 tests in 24 suites. `swift build --product Marketplace` completes.
    - The three tools that the review runs were run on the 19 changed files. `swiftlint` with the rule set of the validators (`no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]`, `missing_docs`, the force rules, the length rules): 0 findings. `swift format lint` with the seven-rule allowlist of `idioms-swift`: 0 findings. `periphery scan --retain-public --skip-build --index-store-path .build/out`: no row on a changed file; the two rows are the pre-existing `var.parameter isolation` on `MarketplaceCache.withWriterLock` (which the `dead-code-swift` rule drops) and one in a test target (which the run does not report).
    - The moved code is the Skills code with 2-space indentation and the changes of the decisions comment: the `layout` parameter and property of the store, the `public` transport init, the `layout:` arguments in `materialize`, the consumer wording, the `EventBroadcaster` without `finishAll()` and with `subscriberCount`. Two long lines of the store (`gitPass`, `installHead`, `checkHead`, `materialize`, `serve`, `duplicateDisplayIDDiagnostics`, `kind(ofRemote:folderName:)`, the `Preparation` init) were joined onto one line where they fit; the text is the same.
    - A grep over `Sources/Marketplace` for `SkillsRegistry`, `SkillDiscovery`, `FrontmatterDecoder`, `RenderPolicy`, `registry` and `import FoundationModelsSkills` finds nothing, and `ModuleBoundaryTests` guards that.
    - Two test failures were met and corrected on the way: the local-folder root path form (decision 9) and the cache folder of a deleted local repository (decision 8, task ^wbtvy0p). Both were test-side changes; no production code changed for them.
    - The `FoundationModelsSkills` working tree shows no change under its `Marketplace` sources, its `Registry/EventBroadcaster.swift`, or its marketplace tests from this card: this card read that repository only.
    - Card text against the source, for the reviewer: the card lists `MarketplaceDiagnostic.swift` among the files to move. It is in `Sources/Marketplace/MarketplaceDiagnostic.swift` since card ^vms0qv0, and this card did not add a second copy. The card does not list `EventBroadcaster`; the store does not build without it (decision 1). Item 7 (commit and push) is the step of the finish loop and of the user.
  timestamp: 2026-09-19T20:56:59.689621+00:00
- actor: claude-code
  id: 01m2xqar1pmwsng5ks567gey16
  text: |-
    ### implement — changed
    - evidence: 20 files. Modified: Package.swift, Tests/MarketplaceTests/MarketplaceTestSupport.swift. Added: Sources/Marketplace/EventBroadcaster.swift, Sources/Marketplace/MarketplaceEvent.swift, Sources/Marketplace/MarketplaceLayerProviding.swift, Sources/Marketplace/MarketplaceStatus.swift, Sources/Marketplace/MarketplaceStore.swift, Tests/MarketplaceFixtures/GatedGitTransport.swift, Tests/MarketplaceFixtures/ManualClock.swift, Tests/MarketplaceFixtures/MarketplaceEventLog.swift, Tests/MarketplaceFixtures/MarketplaceStoreFixture.swift, Tests/MarketplaceFixtures/TestSignal.swift, Tests/MarketplaceTests/EventBroadcasterTests.swift, Tests/MarketplaceTests/MarketplaceLocalSourceTests.swift, Tests/MarketplaceTests/MarketplacePinTests.swift, Tests/MarketplaceTests/MarketplacePolicyTests.swift, Tests/MarketplaceTests/MarketplaceProvenanceTests.swift, Tests/MarketplaceTests/MarketplaceStoreTests.swift, Tests/MarketplaceTests/MarketplaceUpdateTests.swift, Tests/MarketplaceTests/ModuleBoundaryTests.swift. RED: `swift build --build-tests` failed with `cannot find type 'MarketplaceEvent' in scope` (exit 1). GREEN: `swift build --build-tests` exit 0, 0 warnings; `swift test` 921 tests in 6 bundles pass, 0 failures, 0 skipped (MarketplaceTests: 325 tests in 24 suites); `swift build --product Marketplace` exit 0. swiftlint 0, swift-format 0, periphery 0 rows on the changed files. No change in `FoundationModelsSkills`. New task ^wbtvy0p records the latent `file://` normalization behavior.
    - next: `/review` moves the card into review. The finish loop commits; the user pushes `main`.
  timestamp: 2026-09-19T20:57:06.870246+00:00
- actor: claude-code
  id: 01m2xqeytjmrzwqmq5fdgkj9tv
  text: |-
    ### test — green
    - evidence: swift build --build-tests — build complete, 0 warnings; swift test — 367 tests in 30 suites passed, 0 failed, 0 skipped
    - next: send the work to review.
  timestamp: 2026-09-19T20:59:24.882610+00:00
- actor: claude-code
  id: 01m2xqg09vcxb0rv43xt445sc7
  text: |-
    ### commit — changed
    - evidence: 3a2dcdb feat(marketplace): move the store, the events, the status, and the layer provider protocol
    - next: run the review step
  timestamp: 2026-09-19T20:59:59.163516+00:00
- actor: claude-code
  id: 01m2xqxzed1y774j4gtnhx5cp9
  text: |-
    ### review — findings
    - evidence: 1 finding — Sources/Marketplace/MarketplaceStore.swift:1395 (swift/access-control: `Preparation` is `private`, but `MarketplaceStore` reads it at line 250; make it `fileprivate`)
    - next: correct the finding, apply the same correction to each `private` type in the file that a sibling type reads, then run the review again on the new checkpoint
  timestamp: 2026-09-19T21:07:37.037975+00:00
- actor: claude-code
  id: 01m2xqyg3njpccddk85a0vqs5e
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 20 files
    - test: green — swift test, 921 passed in 6 bundles, 0 failed, 0 skipped
    - commit: 3a2dcdb
    - review: findings — Sources/Marketplace/MarketplaceStore.swift:1395 (swift/access-control: `Preparation` is `private` but a sibling type reads it; make it `fileprivate`)
  timestamp: 2026-09-19T21:07:54.101132+00:00
- actor: claude-code
  id: 01m2xr950a28w2fcpry2tg4yrg
  text: |-
    Picked up again for the one open review finding (`swift/access-control` on `Preparation`). What was done and why:

    - `Sources/Marketplace/MarketplaceStore.swift`: `private struct Preparation` is now `fileprivate struct Preparation`, and its doc comment gets the sentence of the file convention (the one on `localSkillsFolderName`): "The store reads it, thus it is `fileprivate` and not `private`."
    - The whole file was checked for the same cause. The file has two top-level declarations: `public actor MarketplaceStore` and `Preparation`. The six other `private` types (`ServedMarketplace`, `PinOverride`, `PassKind`, `PassResult`, `InFlightPass`, `Materialized`) are nested in the actor and only the actor's own members read them, thus `private` is correct for them and they stay. `GitRemote`, `PreparedKind` and `PreparedSource` were already `fileprivate`, because `Preparation` reads them.
    - TDD framing: at file scope, Swift gives `private` and `fileprivate` the same reach, thus no behavior test can go RED on this change. It is a REFACTOR step, and the guard is that the existing suite stays green through it. No source-text lint test was added for one file.
    - The default `swift format lint` configuration reports `[FileScopedDeclarationPrivacy] replace 'fileprivate' with 'private' on file-scoped declarations` on the changed line. That is not a conflict: the `idioms-swift` gate of the review keeps seven named rules and drops every other tag, and `FileScopedDeclarationPrivacy` is not one of the seven. The `swift/access-control` rule is the one the review enforces, and the change obeys it.
    - Discovery outside this file: `CatalogResolver.swift` (`Diagnosed<Value>`, `CatalogReader`) and `SnapshotWriter.swift` (`SnapshotRun`) hold top-level `private struct` types with the same cause. The order bounds this pass to the file of the finding, thus they are a new task, not an edit here.
    - No file in `FoundationModelsSkills` was touched.
  timestamp: 2026-09-19T21:13:43.178031+00:00
- actor: claude-code
  id: 01m2xr9q8kbny6vb38brkyn56d
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/Marketplace/MarketplaceStore.swift (`private struct Preparation` is now `fileprivate struct Preparation`, plus one doc sentence that says why). The finding in `## Review Findings (2026-09-19 16:00)` is checked. `swift build --build-tests` exit 0, 0 warnings; `swift test` 367 tests in 30 suites passed, 0 failed, 0 skipped. The `idioms-swift` allowlist has no `FileScopedDeclarationPrivacy`, thus the default `swift format lint` line on it is not a review finding. New task ^j03dz5j records the same cause in CatalogResolver.swift and SnapshotWriter.swift. No change in FoundationModelsSkills. Not committed.
    - next: `/review` on the working tree moves the card into review. The finish loop commits; the user pushes `main`.
  timestamp: 2026-09-19T21:14:01.875475+00:00
- actor: claude-code
  id: 01m2xrek7hb7519sw379a9fp12
  text: |-
    ### test — green
    - evidence: swift build --build-tests (0 warnings, 0 errors); swift test — 367 tests in 30 suites, 0 failures, 0 skipped
    - next: ready for review
  timestamp: 2026-09-19T21:16:41.585534+00:00
depends_on:
- 01M2XDHMCZ9SDZ8F4EPNQDCD57
position_column: doing
position_ordinal: '80'
title: Move MarketplaceStore, the events, the status and the layer provider protocol
---
## What

In the `Marketplace` target, move the actor that owns the marketplace state, and the protocol that a consumer reads its layers through. After this card, this package holds the whole marketplace implementation, and a consumer only needs `MarketplaceStore` and `MarketplaceLayerProviding`.

1. Move these files from `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/` into `Sources/Marketplace/`, with 2-space indentation and the same type names: `MarketplaceStore.swift`, `MarketplaceEvent.swift`, `MarketplaceDiagnostic.swift`, `MarketplaceStatus.swift`, and from `MarketplaceLayerProviding.swift` the types `MarketplaceProvenance`, `MarketplaceLayer` (without `grants`) and the protocol `MarketplaceLayerProviding`. Do **not** move `MarketplaceProvenanceIndex`: it is keyed by the discovery layer index of `SkillsRegistry`, so it stays in Skills.
2. `MarketplaceStore.init` takes the `MarketplaceLayout` value of the catalog card (`documentName`, `excludedDirectoryNames`, `partialsDirectoryName`) after `sources:`. It passes the layout to `CatalogResolver` and `SnapshotWriter`. The `localSkillsFolderName` constant (`skills`, the folder a `file://` source with no `path` reads) stays, because it is the repository convention of the catalog format.
3. The public surface of the store does not change otherwise: `marketplaceLayers()`, `layerUpdates`, `events`, `diagnostics`, `start()`, `stop()`, `check()`, `update(_:force:)`, `pin(_:sha:)`, `unpin(_:)`, and `cacheDirectory(environment:)`. One access change: the init that takes `transport:` and `clock:` becomes `public`, because `@testable import` does not cross a package boundary and the Skills tests that stay behind build a store with a transport double and a manual clock.
4. Doc comments that name `SkillsRegistry` change to "the consumer" or "the registry of the host". The doc of `MarketplaceLayerProviding` says: the layers a consumer puts below its local stack, lowest precedence first, and one signal for each change.
5. Move the tests into `Tests/MarketplaceTests/`: `MarketplaceStoreTests.swift`, `MarketplaceUpdateTests.swift`, `MarketplacePinTests.swift`, `MarketplacePolicyTests.swift`, and the store half of `MarketplaceLocalSourceTests.swift` (the `file://` source is read directly, the seed folder is read only, and the transport is never called). The tests that assert through `SkillsRegistry` stay in Skills.
6. Put the shared test doubles into the exported `MarketplaceFixtures` target as public types, not into `Tests/MarketplaceTests/`: `MarketplaceStoreFixture` of the Skills `MarketplaceTestSupport` without its `makeRegistry` method (it builds a temporary cache, a temporary local root and a store), and from the Skills `MarketplaceUpdateTestSupport.swift` the `ManualClock`, `GatedGitTransport`, `MarketplaceEventLog` and `TestSignal` types. The Skills tests that stay behind import them from `MarketplaceFixtures`.
7. Commit the work of this card and of the four cards before it, and push to `main`. `FoundationModelsSkills` names this package as a remote `main` dependency, so work that stays in the local folder does not reach it.
8. Do not delete anything in `FoundationModelsSkills`.

## Acceptance Criteria

- [ ] `MarketplaceStore` here gives the same behavior as in Skills for a `file://` git source: cold start, `check()`, `update()`, a failed fetch that keeps the last snapshot, `pin` and `unpin` with `applyUpdates: .nextLaunch`, `stop()`, the fetch timeout, and one `layerUpdates` value for each swap.
- [ ] `marketplaceLayers()` gives one layer for each source, lowest first, with the source `.marketplace`, the stable `current` root, and the provenance (id, url, sha, catalog version).
- [ ] No file in `Sources/Marketplace` names `SkillsRegistry`, `SkillDiscovery`, `FrontmatterDecoder` or `RenderPolicy`.
- [ ] The whole `Marketplace` target has no `import` of a Skills module, and `swift build --product Marketplace` links libgit2 and the core target only (plus Yams).
- [ ] `MarketplaceStoreFixture`, `ManualClock`, `GatedGitTransport`, `MarketplaceEventLog` and `TestSignal` are public in `MarketplaceFixtures`, and the store init with `transport:` and `clock:` is public.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.
- [ ] The work is committed and pushed to `main` of this repository.

## Tests

- [ ] `Tests/MarketplaceTests/MarketplaceStoreTests.swift`: the §6.1, §6.2, §7.3 and §7.6 cases of the Skills `marketplace.md` over a `GitFixtureRepository`, with `RecordingGitTransport` counts.
- [ ] `Tests/MarketplaceTests/MarketplaceUpdateTests.swift`: the §8.1 to §8.3 cases with `ManualClock`; no test waits on real time.
- [ ] `Tests/MarketplaceTests/MarketplacePinTests.swift`: pin, unpin, and the pending snapshot in `state.json`.
- [ ] `Tests/MarketplaceTests/MarketplacePolicyTests.swift`: a refused source makes no transport call and no cache folder.
- [ ] `Tests/MarketplaceTests/MarketplaceLocalSourceTests.swift`: a `file://` folder source gives a watchable layer with zero transport calls.
- [ ] `Tests/MarketplaceTests/ModuleBoundaryTests.swift`: no file under `Sources/Marketplace` names a Skills type from the list above.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#marketplace #cross-repo

## Review Findings (2026-09-19 16:00)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 20 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/Marketplace/MarketplaceStore.swift:1395` `swift/access-control` — `Preparation` is marked `private`, but it is accessed from `MarketplaceStore` (a different type in the same file) on line 250. The access level should be `fileprivate` to allow this sibling-type access. Change line 1395 from `private struct Preparation` to `fileprivate struct Preparation`.
