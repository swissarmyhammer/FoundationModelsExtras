---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7jprbkktra980srh5bdvk2j
  text: |-
    Research done.
    - `MarketplaceSourceError` is `internal`. A public case `.invalidSource(MarketplaceSourceError)` cannot compile with an internal payload. The card names this public case, thus the implement step makes `MarketplaceSourceError` and its `description` public. No other change to that type.
    - `MarketplaceIdentity.preFetchKey(for:)` gives the id. It parses the URL first, thus a bad URL gives no id also when the source has an alias.
    - `EventBroadcaster<Element>` fits `changes()`: one stream for each subscriber, `nonisolated` subscribe.
    - An actor method that awaits the storage two times (load, then save) is reentrant. Two concurrent writes on one registry can then lose one change. The registry therefore runs its writes one at a time (a FIFO wait inside the actor).
    - No `docs/marketplaces.md` exists. The marketplace doc is the `## Remote layers: MarketplaceStore` section of `docs/REFERENCE.md`. The registry doc goes there as a new subsection.
    - TestudoApp has its own `MarketplaceEntry` type, but it does not import `Marketplace`, thus no name clash.
  timestamp: 2026-11-16T17:33:54.675931+00:00
- actor: claude-code
  id: 01m7jqjfc0hkz5th6htjvk8f0w
  text: |-
    Implementation landed (TDD, each test batch was red before its code).
    - New: `MarketplaceSourceStorage` + `InMemoryMarketplaceSourceStorage`, `MarketplaceEntry` (Identifiable; internal init from a source), `MarketplaceRegistry` (actor), `MarketplaceRegistryChange`, `MarketplaceRegistryError` (LocalizedError).
    - Changed: `MarketplaceSourceError` and its `description` are now public, because the public case `.invalidSource(MarketplaceSourceError)` needs a public payload. No behavior change.
    - Each write validates the full new list (one place for the duplicate check). The registry runs writes one at a time with a FIFO wait inside the actor. Without it, the test `concurrentAddsAllLandInTheStoredList` failed: concurrent adds lost changes, because the actor is reentrant across the load and save awaits.
    - Docs: new subsection `### One marketplace at a time: MarketplaceRegistry` in `docs/REFERENCE.md` (no `docs/marketplaces.md` exists). It tells the host to stop the old store and make a new store from `marketplaces()` on each change.
    - Build note: stale `*.cstemp` files under `.build/out/Products/Debug/*.xctest` made CodeSign fail one time. Deleting them fixed the build.
    - The only warning in the build output is `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, from the build system for the mlx-swift bundle. It is not a compiler warning, and it is not from this change.
  timestamp: 2026-11-16T17:48:10.496538+00:00
- actor: claude-code
  id: 01m7jqjj1p08nm6xpedz7azt2k
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/Marketplace/MarketplaceSourceStorage.swift, Sources/Marketplace/MarketplaceEntry.swift, Sources/Marketplace/MarketplaceRegistry.swift, Sources/Marketplace/MarketplaceRegistryChange.swift, Sources/Marketplace/MarketplaceRegistryError.swift, Sources/Marketplace/MarketplaceSourceError.swift, Tests/MarketplaceTests/MarketplaceRegistryTests.swift, docs/REFERENCE.md. `swift test --filter Marketplace`: 433 + 11 tests passed. `swift test`: 1940 + 35 tests passed, 0 compiler warnings.
    - next: review
  timestamp: 2026-11-16T17:48:13.238033+00:00
- actor: claude-code
  id: 01m7jqsxfg93jpces7wtjy78gf
  text: |-
    ### test — green
    - evidence: swift test — 7 test runs passed (156, 40, 46, 26, 433, 1940, 35 tests), 0 failures, 0 skipped, 0 compiler warnings in the changed files. The only build line is the mlx-swift_Cmlx.bundle build-system line, which is not a compiler warning. The MarketplaceRegistryTests suite (32 tests) ran 3 more times alone: 3 passes, no flaky result.
    - next: review
  timestamp: 2026-11-16T17:52:14.320587+00:00
- actor: claude-code
  id: 01m7jr0bm28a13mcgy4j4kj7e8
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (b08dd2c): 0 findings, 0 confirmed, 1 refuted, 7 files attempted, 0 failed. Not reviewed: docs/REFERENCE.md (no validator matches this file), 2 files in .kanban/ (ignore rule).
    - next: none. The task is in done.
  timestamp: 2026-11-16T17:55:45.410235+00:00
- actor: claude-code
  id: 01m7jr0sh0fgfre9nnqexxqcck
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files
    - test: green — swift test, 7 runs passed, 0 failed; MarketplaceRegistryTests x3, 32 passed each time
    - commit: b08dd2c
    - review: clean — 0 findings
  timestamp: 2026-11-16T17:55:59.648093+00:00
position_column: done
position_ordinal: ffeb80
title: 'Marketplace registry: add, update, remove, list and get one marketplace at a time, through a host port'
---
## Why

Today a host changes a skill marketplace only when it writes the whole source list again (for example `tools.skills.marketplaces` in the ACPAgent settings). The user needs to add, change and remove one marketplace at a time. Other packages implement the surfaces on this API: FoundationModelsSkills adds the GraphQL endpoint and the model operations, and ACPAgent supplies the storage through its user settings layer.

`MarketplaceStore` keeps its source list fixed from its init. Thus the item API is a separate type in the `Marketplace` module. The host makes a new store from the new list when it gets a change.

## What

In `Sources/Marketplace`:

- `MarketplaceSourceStorage`, a public protocol (the host port): `func loadSources() async throws -> [MarketplaceSource]` and `func saveSources(_ sources: [MarketplaceSource]) async throws`.
- `InMemoryMarketplaceSourceStorage`, a public storage that holds the list in memory, for tests and simple hosts.
- `MarketplaceEntry`, a public value: `id` (the pre-fetch key, the same display id that `MarketplaceStore` uses: the alias, else the repository name) and `source`.
- `MarketplaceRegistry`, a public actor over a storage:
  - `marketplaces() async throws -> [MarketplaceEntry]`, in list order.
  - `marketplace(id:) async throws -> MarketplaceEntry?`
  - `add(_ source:) async throws -> MarketplaceEntry`: it appends to the end of the list.
  - `update(id:to:) async throws -> MarketplaceEntry`: it replaces the source in its position. The new source can have a different id when the id is not used by another entry.
  - `remove(id:) async throws -> MarketplaceEntry`: it returns the removed entry.
  - `changes() -> AsyncStream<MarketplaceRegistryChange>`: `.added(MarketplaceEntry)`, `.updated(previousID: String, MarketplaceEntry)`, `.removed(MarketplaceEntry)`. A change is sent only after the storage saved the list.
- `MarketplaceRegistryError`, public, `LocalizedError`: `.duplicateMarketplace(id:)`, `.unknownMarketplace(id:)`, `.invalidSource(MarketplaceSourceError)`.
- Each write reads the list from the storage, validates it, changes it, and saves it. Thus a change that the host makes in another place is not lost. A failed save sends no change and keeps the stored list.

## Acceptance

- [x] Each operation has a Swift Testing test with the in-memory storage, written before the code.
- [x] Add of a duplicate id throws `duplicateMarketplace`, and the stored list does not change.
- [x] Update and remove of an unknown id throw `unknownMarketplace`.
- [x] A source with a bad URL or an unusable key throws `invalidSource` with the error of the parser.
- [x] Update to an id that another entry has throws `duplicateMarketplace`.
- [x] Each successful write sends one change, in order. A failed write sends none.
- [x] A storage error comes out unchanged, and sends no change.
- [x] `docs/marketplaces.md` (or the doc of the module) tells how a host uses the registry with the store.
- [x] `swift test` is green with no warnings.

#marketplace