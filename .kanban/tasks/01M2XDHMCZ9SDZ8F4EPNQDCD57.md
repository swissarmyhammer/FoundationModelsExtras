---
depends_on:
- 01M2XDHD4KZ7E1WWRD0VMS0QV0
- 01M2XDHD6WSMB5PQ0707Z1W5F8
position_column: todo
position_ordinal: '8380'
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