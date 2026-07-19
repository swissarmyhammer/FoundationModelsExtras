---
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: todo
position_ordinal: '8980'
title: 'DocCoverageTests: fail on undocumented public API'
---
## What
Adopt the family's doc-coverage convention (see `FoundationModelsShelltool`'s `DocCoverageTests` and its Package.swift comments): a test that parses every source file under `Sources/FoundationModelsExtras` with SwiftSyntax and fails on any undocumented `public` declaration. Note: this is family convention, not plan.md scope — kept because every sibling package enforces it.

- Add `swift-syntax` (`SwiftSyntax` + `SwiftParser` products) to the **test target only** — test-only tooling, does not count against the plan.md §5 runtime dependency budget (Foundation + Stencil), matching how Shelltool declares it.
- Port/adapt the sibling's scanner: `Tests/FoundationModelsExtrasTests/DocCoverageTests.swift`.

## Acceptance Criteria
- [ ] The scanner reports a violation for an in-memory source snippet containing an undocumented public declaration (automated regression check embedded in the test — proves the scanner works, not just that the tree is clean)
- [ ] The scanner reports zero violations for `Sources/FoundationModelsExtras` (the tree is actually documented)
- [ ] swift-syntax appears only in the test target's dependencies

## Tests
- [ ] `DocCoverageTests.swift` is itself the test; run `swift test`, expect pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.