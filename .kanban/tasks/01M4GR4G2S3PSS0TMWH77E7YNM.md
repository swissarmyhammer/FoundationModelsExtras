---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Marketplace: remove catalogVersion and the catalog display id from the public API and the state file'
---
## Problem

Task ^wcm7ydh removed the catalog read. Now no install sets a catalog version or a catalog `name`. These public fields stay, but a new install gives `nil` or the pre-fetch key:

- `MarketplaceProvenance.catalogVersion`, and the `@<version>` branch of `MarketplaceProvenance.displayText`.
- `MarketplaceListing.catalogVersion`.
- `MarketplaceStateRecord.catalogVersion`, `MarketplaceStateRecord.displayID`, `MarketplacePendingSnapshot.catalogVersion` and `MarketplacePendingSnapshot.displayID` (the state file).
- The `catalogVersion:` parameter of `MarketplaceStore.serve(atIndex:cache:sha:displayID:catalogVersion:)`.

Task ^wcm7ydh kept them because its card does not name them, and they are public API.

## Work

- [ ] Decide with the user: remove the fields (a breaking change), or keep them for the old state files.
- [ ] If removed: delete the fields, update `displayText`, the listing, the store and the tests (`MarketplaceProvenanceTests`, `MarketplaceListingTests`, `MarketplaceCacheTests`).
- [ ] Update README, CHANGELOG and plan.md.