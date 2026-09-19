---
depends_on:
- 01M2XDHMCZ9SDZ8F4EPNQDCD57
position_column: todo
position_ordinal: '8480'
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