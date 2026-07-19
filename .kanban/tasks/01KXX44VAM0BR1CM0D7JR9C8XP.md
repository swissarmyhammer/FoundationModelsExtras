---
position_column: todo
position_ordinal: '80'
title: 'Scaffold package: Package.swift, targets, CI'
---
## What
Create the Swift package skeleton for FoundationModelsExtras, mirroring sibling conventions (see `../FoundationModelsShelltool/Package.swift`).

- `Package.swift`: `// swift-tools-version: 6.2`, platform macOS 27 per plan.md (use `.macOS(.v27)`; if that enum case does not exist in tools 6.2, fall back to `.v26` like Shelltool and note it), library product `FoundationModelsExtras` from target at `Sources/FoundationModelsExtras`, test target `FoundationModelsExtrasTests` at `Tests/FoundationModelsExtrasTests` using swift-testing.
- Dependency budget per plan.md §5: **Foundation + Stencil only** (PathKit rides along transitively). Add `https://github.com/stencilproject/Stencil.git` pinned with `exact:` to the current latest release. No Yams, no family imports.
- A minimal placeholder source file (e.g. an empty enum with a doc comment) so the package builds, and one trivial swift-testing test so `swift test` runs.
- `.github/workflows/ci.yml` mirroring Shelltool's verbatim: `uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` on push to main / pull_request / workflow_dispatch with the same concurrency group.
- `.gitignore` for `.build/` etc. (copy a sibling's).

## Acceptance Criteria
- [ ] `swift build` succeeds on a clean checkout
- [ ] `swift test` succeeds and runs at least one swift-testing test
- [ ] `Package.resolved` pins Stencil to an exact version
- [ ] `.github/workflows/ci.yml` matches the sibling pattern (reusable swift-ci workflow)
- [ ] No dependencies beyond Stencil (and its transitive PathKit) in Package.swift

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/SmokeTests.swift` — one trivial `@Test` proving the test target links against the library
- [ ] Run `swift test`; expect all tests pass, zero warnings

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.