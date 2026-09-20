---
comments:
- actor: claude-code
  id: 01m3011aw6j2pvdtkwhwrnw3j5
  text: |-
    ### finish — note on the board and on the push
    - The "Where the work is" section tells a reader to move the card to the Extras board. The card is already on the FoundationModelsExtras board, which is the board of this package, thus no move is necessary.
    - The finish loop commits a local checkpoint on each iteration and never pushes. The push to `main` is the step of the user after the loop.
    - next: the loop runs implement, test, commit and review on this card.
  timestamp: 2026-09-20T18:25:13.094243+00:00
- actor: claude-code
  id: 01m301c4ch63rm114pgfpgpyem
  text: |-
    ### Research

    Read the `Marketplace` target and the `skills marketplace` CLI of the sibling repository (read only, no edit there).

    What the CLI does, and what the new API must replace:
    - `MarketplaceRow.rows(of:cacheDirectory:)` reads `<cache>/state.json` with `MarketplaceState.load`, then maps each source. It opens no connection.
    - The six columns are `ID, URL, CURRENT, CATALOG, CHECKED, STATUS`. The status ladder is: a folder on this computer gives `local folder` and returns at once; else `record.lastError`; else `not installed` when there is no current commit; else `pinned` or `ready`.
    - `holdsOneCommit`: `record.pinnedSha != nil` wins; then `record.unpinned == true` gives false; else `source.isPinned`.
    - A source of no supported form still gets a row: the id is the alias, the URL is `nil`, and the status is `String(describing: error)`. A `nil` URL is the privacy rule: a URL that carries a credential is never shown.
    - The id lookup of `check`, `update`, `pin`, `unpin` and `remove` matches the display id, then the pre-fetch key.

    Decisions for this card:
    - `MarketplaceListing` goes in a file of its own, with the derivation beside the value. `MarketplaceStore.listings(of:cacheDirectory:)` forwards to it, so the store file does not grow.
    - `id` is the display id, else the pre-fetch key, else the alias. It is the empty text when the source gives none of the three; the `-` of the CLI is a rendering choice that stays in the CLI.
    - `key` is `nil` for a source of no supported form, because such a source has no pre-fetch key. The alias still names it through `id`.
    - A listing of a folder on this computer carries no commit, no catalog version, no last check and no error, as the CLI row does.

    Tests:
    - The pin tests drive `MarketplaceStore.pin(_:sha:)` and `unpin(_:)`, which write `state.json` with no network work.
    - The other tests write one `MarketplaceStateRecord` into the state file, under the folder name that `MarketplaceIdentity.cacheFolderName(key:normalizedURL:)` gives.
    - `ModuleBoundaryTests` gets the guard that the five cache-layout types stay `internal`.
  timestamp: 2026-09-20T18:31:06.897951+00:00
- actor: claude-code
  id: 01m301sys0p7h3abcajsssep1f
  text: |-
    ### Work record

    TDD order: the test file went in first and the run failed to build with `type 'MarketplaceStore' has no member 'cacheDirectoryVariable'` and `'seedDirectoryVariable'`. The API then made the 17 tests of the suite pass.

    The boundary guard `noCacheLayoutTypeStandsOnTheModuleSurface` guards a property that already holds, thus it could not start red on its own. To prove it can fail, `MarketplaceCache` was made `public` for one run: the test failed with `offenders → ["/Sources/Marketplace/MarketplaceCache.swift: MarketplaceCache"]`. The type is `internal` again.

    Notes for the next agent:
    - `MarketplaceStore.pin(_:sha:)` and `unpin(_:)` write `state.json` with no network work and no `start()`, thus a pin test needs no git fixture. The other tests write one `MarketplaceStateRecord` into the state file directly.
    - `MarketplaceStore.listings(of:cacheDirectory:)` forwards to `MarketplaceListing.listings(of:cacheDirectory:)`, which is `internal` and lives beside the value. `MarketplaceStore.swift` is already long, thus the derivation is not in it.
    - The `id` of a source that has a bad URL and no alias is the empty text. The `-` of the CLI is a rendering choice and stays in the CLI.
    - `README.md` gets a paragraph AFTER the fenced block of the marketplace section. `ReadmeSnippetTests` reads the FIRST fenced Swift block under that heading and compares it with the test copy, thus a new block before it would break that suite.
  timestamp: 2026-09-20T18:38:39.904385+00:00
- actor: claude-code
  id: 01m301t35n4p7p0kcs7gk6ad6f
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/Marketplace/MarketplaceListing.swift (new), Sources/Marketplace/MarketplaceStore.swift, Tests/MarketplaceTests/MarketplaceListingTests.swift (new), Tests/MarketplaceTests/ModuleBoundaryTests.swift, README.md, CHANGELOG.md. `swift test`: 6 targets, 434 + 350 + 125 + 44 + 34 + 26 tests passed, zero failures, zero warnings.
    - next: `/review` reads the change. The card stays in `doing`.
  timestamp: 2026-09-20T18:38:44.405284+00:00
- actor: claude-code
  id: 01m301yjhn10r41v32mdqh1ym1
  text: |-
    ### test — green
    - evidence: swift test — 434 tests, 33 suites, 0 failed, 0 skipped; swift build — 0 warnings; diagnostics check working — 0 errors, 0 warnings
    - next: ready for review
  timestamp: 2026-09-20T18:41:11.221113+00:00
- actor: claude-code
  id: 01m3022mptvjcmh88d9sk8h93t
  text: |-
    ### commit — changed
    - evidence: 37e6116 feat(marketplace): add a public read API for the skills CLI
    - next: review the change
  timestamp: 2026-09-20T18:43:24.506632+00:00
- actor: claude-code
  id: 01m30272y415n5vy6egrmhg6sg
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 37e6116) — 7 validators attempted, 0 failed, 0 findings. 4 files reviewed: Sources/Marketplace/MarketplaceListing.swift, Sources/Marketplace/MarketplaceStore.swift, Tests/MarketplaceTests/MarketplaceListingTests.swift, Tests/MarketplaceTests/ModuleBoundaryTests.swift. README.md and CHANGELOG.md got no review, because no validator reads a Markdown file. The 4 `.kanban/` files are out of scope by a `.reviewignore` rule. No prior review finding is open.
    - next: the card moves to `done`. The user pushes when the user wants to.
  timestamp: 2026-09-20T18:45:50.148718+00:00
- actor: claude-code
  id: 01m3027bemgyxn6121z11xq801
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files. New `Sources/Marketplace/MarketplaceListing.swift` and `Tests/MarketplaceTests/MarketplaceListingTests.swift`, plus `MarketplaceStore.swift`, `ModuleBoundaryTests.swift`, `README.md` and `CHANGELOG.md`.
    - test: green — `swift test` runs 6 test targets and each one passes with exit 0: 434, 350, 125, 44, 34 and 26 tests, 0 failed, 0 skipped. The build gives no warning.
    - commit: 37e6116 — feat(marketplace): add a public read API for the skills CLI
    - review: clean — 7 validators attempted, 0 failed, 0 findings, over the 4 Swift files of the commit. The task moved to `done`.
    - note: the push to `main` stays with the user after the loop.
  timestamp: 2026-09-20T18:45:58.868956+00:00
position_column: done
position_ordinal: b680
title: Give the Marketplace product the public read API that the skills CLI needs
---
## Where the work is

This card is on the FoundationModelsExtras board, where the work is. This card stands here only because this board cannot hold a card of another board. Move it, or copy it, to the Extras board before you start.

## Why

`^sg5cf2n` deletes the marketplace code of `FoundationModelsSkills` and consumes the Extras `Marketplace` product. The registry side maps cleanly: `MarketplaceLayerProviding`, `MarketplaceLayer`, `MarketplaceProvenance`, `MarketplaceStore`, `MarketplaceLayout`, `MarketplaceSource`, `MarketplacePolicy`, `MarketplaceConfig`, `MarketplaceStatus`, `MarketplaceEvent`, `MarketplacePinError`, `GitTransport` and `LibGit2Transport` are all public at `1c150fb`.

The `skills marketplace` CLI group does **not** map. It reads the cache state file to make the rows of `marketplace list`, and it makes the pre-fetch key of a new source for `marketplace add`. Every type that does this work is `internal` in the `Marketplace` target:

- `MarketplaceCache` — `cacheVariable`, `seedVariable`, `stateFile(inCacheDirectory:)`
- `MarketplaceState`, `MarketplaceStateRecord` — `displayID`, `currentSha`, `catalogVersion`, `lastChecked`, `lastError`, `pinnedSha`, `unpinned`
- `MarketplaceIdentity` — `preFetchKey(for:)`, `cacheFolderName(key:normalizedURL:)`
- `MarketplaceLocation` — `normalizedURL`, and the `.git` test that tells a remote from a folder on this computer

A consumer cannot reach one of them. Thus `marketplace list`, and the id lookup of `check`, `update`, `pin`, `unpin` and `remove`, cannot be written against the public API.

## What to add

Add **one** public read API. Do not make the cache types public: that would export the cache layout.

1. A public value that names one marketplace as `marketplace list` shows it. One suggested shape:

```swift
public struct MarketplaceListing: Sendable, Hashable {
    public var id: String            // the display id, else the pre-fetch key, else the alias
    public var key: String?          // the pre-fetch key
    public var url: String?          // the normalized URL, or nil for a URL of no supported form
    public var currentSha: String?
    public var catalogVersion: String?
    public var lastChecked: Date?
    public var isLocalFolder: Bool
    public var holdsOneCommit: Bool  // the pin of the user wins over the sha field, and an unpin beats it
    public var lastError: String?    // the message of the last failure, else the message of a bad source
}
```

2. A public call that gives one listing for each source. The call reads the state file and opens no connection, because `marketplace list` does no network work:

```swift
public static func listings(of sources: [MarketplaceSource], cacheDirectory: URL) -> [MarketplaceListing]
```

3. Public constants for the two environment variables that a host and a test both set:

```swift
public static let cacheDirectoryVariable = "SKILLS_MARKETPLACE_CACHE"
public static let seedDirectoryVariable = "SKILLS_MARKETPLACE_SEED"
```

Put 2 and 3 on `MarketplaceStore`, beside the public `MarketplaceStore.cacheDirectory(environment:)` that is there now.

## Acceptance Criteria

- [ ] A package that imports `Marketplace` only can make the six columns of `marketplace list`: id, URL, current commit, catalog version, last check, status.
- [ ] A package that imports `Marketplace` only can find the pre-fetch key of one `MarketplaceSource` before a fetch.
- [ ] A package that imports `Marketplace` only can name the cache folder variable and the seed folder variable.
- [ ] `MarketplaceCache`, `MarketplaceState`, `MarketplaceStateRecord`, `MarketplaceIdentity` and `MarketplaceLocation` stay `internal`.
- [ ] The Extras tests stay green, and the public API has documentation.

## Tests

- [ ] A test proves that a listing of a marketplace with a pin says that the marketplace holds one commit.
- [ ] A test proves that a listing of a marketplace with no snapshot carries no commit.
- [ ] A test proves that a listing of a folder on this computer says so.
- [ ] A test proves that a listing carries the message of the last failure.

#marketplace #extras #loading-boundary