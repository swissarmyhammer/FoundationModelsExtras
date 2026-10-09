---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4gv09ts4azsky3x0esevh5h
  text: |-
    Picked up. Decision from the dispatcher (the user path): remove, as the title says.

    Research:
    - Public fields: MarketplaceProvenance.catalogVersion (+ the `@<version>` branch of displayText), MarketplaceListing.catalogVersion (in MarketplaceLayerProviding.swift and MarketplaceListing.swift).
    - State file: MarketplaceStateRecord.catalogVersion/displayID and MarketplacePendingSnapshot.catalogVersion/displayID use synthesized Codable. Synthesized decode ignores unknown keys, thus an old state.json keeps decoding after the fields go. The next save drops the old keys.
    - Store: serve(atIndex:cache:sha:displayID:catalogVersion:), adopt(pending:), install(), recordInstall(), servedFromCache() and names(index:id:) read or write these fields. With no stored display id, the display id is always the pre-fetch key (prepared[index].key). Thus serve() loses both parameters, and published() loses `installedID`.
    - Behavior change: before, a display id that an old state file held named the layer and the listing until the next install. After, the pre-fetch key names them at once.
    - Docs: README (listing paragraph names "the catalog version"), CHANGELOG Unreleased entry of ^wcm7ydh, plan.md (the scan decision paragraph).
  timestamp: 2026-10-09T17:22:34.969034+00:00
- actor: claude-code
  id: 01m4gvs84zxjtm906ptasa9tzw
  text: |-
    Implementation landed.

    - RED: 3 new tests failed for the expected reason (old displayID/catalogVersion named the layer and the listing; save kept the old keys). GREEN after the change.
    - Removed: MarketplaceProvenance.catalogVersion (+ init parameter, + `@<version>` branch of displayText), MarketplaceListing.catalogVersion (+ init parameter), MarketplaceStateRecord.catalogVersion/displayID, MarketplacePendingSnapshot.catalogVersion/displayID.
    - Store: serve(atIndex:cache:sha:) has no displayID and no catalogVersion parameter. displayID(atIndex:) now returns prepared[index].key. published() lost `installedID`. recordInstall() lost `displayID`. servedFromDisk(prepared:) and servedFromCache(entry:cache:leased:) no longer take a state (it fed only the removed fields). names(index:id:) matches the pre-fetch key only.
    - Behavior change: pin/unpin/update by an old catalog `name` now gives unknownMarketplace. An old state.json still decodes (synthesized Codable ignores unknown keys); the next save drops the keys.
    - Test support: MarketplaceTestSupport.addEarlierCatalogKeys(displayID:catalogVersion:toStateFile:) writes the old keys into a state file by raw JSON.
    - Docs: README listing paragraph, CHANGELOG new breaking entry at the top of Unreleased, plan.md §12 scan paragraph. Doc comments in MarketplaceIdentity, MarketplacePinError and MarketplaceDiagnostic no longer name a separate display id.
    - Note: the build prints `warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)`. It is a SwiftPM build-graph warning of the mlx dependency. It was present in the RED run before any production change; it does not come from this diff.
  timestamp: 2026-10-09T17:36:12.447461+00:00
- actor: claude-code
  id: 01m4gvsbvt3pzz76z2kch0fb01
  text: |-
    ### implement — changed
    - evidence: 17 files — Sources/Marketplace/{MarketplaceState,MarketplaceLayerProviding,MarketplaceListing,MarketplaceStore,MarketplaceIdentity,MarketplacePinError,MarketplaceDiagnostic}.swift, Tests/MarketplaceTests/{MarketplaceProvenanceTests,MarketplaceListingTests,MarketplaceCacheTests,MarketplaceStoreTests,MarketplaceTestSupport}.swift, README.md, CHANGELOG.md, plan.md (+ the two .kanban files of this task). `swift test`: "Test run with 131 tests in 12 suites passed", "Test run with 40 tests in 4 suites passed", "Test run with 44 tests in 10 suites passed", "Test run with 26 tests in 5 suites passed", "Test run with 382 tests in 28 suites passed", "Test run with 913 tests in 87 suites passed ... with 11 known issues" (the 11 known issues are the pre-existing withKnownIssue cases of TelemetryCaptureTests). XCTest: 6 x "Executed 0 tests, with 0 failures". 0 failures.
    - next: /review
  timestamp: 2026-10-09T17:36:16.250384+00:00
- actor: claude-code
  id: 01m4gvz680eqsyrxrswy00pdmy
  text: |-
    ### test — green
    - evidence: swift test — Test run with 131 tests in 12 suites passed; 40 tests in 4 suites passed; 44 tests in 10 suites passed; 26 tests in 5 suites passed; 382 tests in 28 suites passed; 913 tests in 87 suites passed with 11 known issues. XCTest lines: 6 lines, each Executed 0 tests, 0 failures. 0 failed, 0 skipped. One build warning (missing creator for mutated node, mlx-swift_Cmlx.bundle), which comes from a dependency build step, not from source.
    - next: none. The 11 known issues come from tests that use withKnownIssue on purpose, in TelemetryCaptureTests.
  timestamp: 2026-10-09T17:39:27.104612+00:00
- actor: claude-code
  id: 01m4gvzp0efhwp6jm82frfwksb
  text: |-
    ### commit — changed
    - evidence: commit subject "feat(marketplace)!: remove catalogVersion and catalog displayID from provenance" (new local commit, not pushed)
    - next: review
  timestamp: 2026-10-09T17:39:43.246660+00:00
- actor: claude-code
  id: 01m4gwfpbh2ce535y68swgx1zs
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (f7095e5). 0 findings, 0 confirmed, 2 refuted. 12 files reviewed. CHANGELOG.md, README.md and plan.md have no matching validator. The .kanban files are excluded by .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-10-09T17:48:27.889149+00:00
- actor: claude-code
  id: 01m4gwfx291swq55sr0kq272hf
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 17 files
    - test: green — swift test, Marketplace 382 passed, core 913 passed, 0 failed
    - commit: f7095e5
    - review: clean — 0 findings
  timestamp: 2026-10-09T17:48:34.761197+00:00
position_column: done
position_ordinal: e680
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

- [x] Decide with the user: remove the fields (a breaking change), or keep them for the old state files. (Decision: remove, as the title says. An old state file that holds the keys still decodes; the next save drops them.)
- [x] If removed: delete the fields, update `displayText`, the listing, the store and the tests (`MarketplaceProvenanceTests`, `MarketplaceListingTests`, `MarketplaceCacheTests`).
- [x] Update README, CHANGELOG and plan.md.