---
position_column: todo
position_ordinal: '8380'
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