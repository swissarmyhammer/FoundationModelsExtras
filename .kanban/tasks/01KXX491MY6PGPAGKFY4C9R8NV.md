---
comments:
- actor: claude-code
  id: 01kxxd88480bbg4gjv4khv0md1
  text: |-
    Implemented DocCoverageTests per the FoundationModelsShelltool convention:

    - Package.swift: added swift-syntax dependency (from "604.0.0-latest"), with SwiftSyntax + SwiftParser products declared only in the testTarget's dependencies. Main library target still depends only on Stencil.
    - Tests/FoundationModelsExtrasTests/DocCoverageTests.swift: ported DocCoverageScanner (SwiftSyntax visitor) + integration test scanning Sources/FoundationModelsExtras, plus the path-escape-throws test.
    - Tests/FoundationModelsExtrasTests/DocCoverageScannerTests.swift: ported unit/regression tests against synthetic fixtures (documented/undocumented struct, function, init, actor, enum case inside public enum, blank-line-separated doc comment, attribute-attached doc comment).
    - Tests/FoundationModelsExtrasTests/PackageRootValidation.swift: ported path-containment helper, adjusted to this package's Tests/FoundationModelsExtrasTests directory depth (still three levels up to package root).

    TDD: wrote DocCoverageScannerTests.swift first referencing the not-yet-existing DocCoverageScanner, ran swift test, confirmed compile failure (cannot find 'DocCoverageScanner' in scope), then added the scanner + remaining test files. Full suite now green: 46/46 tests pass, zero warnings on swift build.

    Dispatched double-check adversarial review agent before declaring done; awaiting its verdict.
  timestamp: 2026-07-19T14:42:30.152429+00:00
- actor: claude-code
  id: 01kxxdc8280y9e7f0ytqjxvz6c
  text: |-
    Double-check adversarial review returned PASS, no findings:
    - swift-syntax confirmed scoped only to the test target in Package.swift (main library target deps remain ["Stencil"]).
    - Scanner logic verified line-by-line against the FoundationModelsShelltool original — no bugs from the port, including PackageRootValidation's three-levels-up path walk (correct for this package's Tests/FoundationModelsExtrasTests directory depth).
    - Fresh `rm -rf .build && swift test` run confirmed by the reviewer: 46/46 tests pass, zero warnings.
    - Confirmed the integration test scans real content (4 source files, 22 public declarations in Sources/FoundationModelsExtras), not a vacuous/empty scan.
    - No dead code, no leftover sibling-package identifiers, no unused imports.

    All acceptance criteria and test checkboxes marked complete on the task description. Leaving in doing for /review.
  timestamp: 2026-07-19T14:44:41.160690+00:00
depends_on:
- 01KXX44VAM0BR1CM0D7JR9C8XP
position_column: doing
position_ordinal: '80'
title: 'DocCoverageTests: fail on undocumented public API'
---
## What
Adopt the family's doc-coverage convention (see `FoundationModelsShelltool`'s `DocCoverageTests` and its Package.swift comments): a test that parses every source file under `Sources/FoundationModelsExtras` with SwiftSyntax and fails on any undocumented `public` declaration. Note: this is family convention, not plan.md scope — kept because every sibling package enforces it.

- Add `swift-syntax` (`SwiftSyntax` + `SwiftParser` products) to the **test target only** — test-only tooling, does not count against the plan.md §5 runtime dependency budget (Foundation + Stencil), matching how Shelltool declares it.
- Port/adapt the sibling's scanner: `Tests/FoundationModelsExtrasTests/DocCoverageTests.swift`.

## Acceptance Criteria
- [x] The scanner reports a violation for an in-memory source snippet containing an undocumented public declaration (automated regression check embedded in the test — proves the scanner works, not just that the tree is clean)
- [x] The scanner reports zero violations for `Sources/FoundationModelsExtras` (the tree is actually documented)
- [x] swift-syntax appears only in the test target's dependencies

## Tests
- [x] `DocCoverageTests.swift` is itself the test; run `swift test`, expect pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.