---
comments:
- actor: claude-code
  id: 01kxx7yass8sca3206g99j7fy4
  text: |-
    Implemented via TDD:

    1. RED: wrote `Tests/FoundationModelsExtrasTests/SmokeTests.swift` (mirrors Shelltool's `ScaffoldTests.swift` pattern — `@testable import FoundationModelsExtras` + an empty `@Test`, no tautological runtime assertion) and `Package.swift` before any source file existed. `swift build` failed correctly: "target 'FoundationModelsExtras' referenced in product 'FoundationModelsExtras' is empty".
    2. GREEN: added `Sources/FoundationModelsExtras/FoundationModelsExtras.swift` (placeholder `public enum FoundationModelsExtras {}` with a doc comment). `swift build` and `swift test` both succeed; 1 test, 0 failures, 0 warnings.

    Details:
    - `.macOS(.v27)` does not exist under `swift-tools-version: 6.2` — confirmed by actually trying it (`'v27' is unavailable ... introduced in PackageDescription 6.4`). Fell back to `.macOS(.v26)` per the task's own fallback instruction, matching Shelltool, and left a comment in Package.swift explaining why.
    - Stencil pinned `exact: "0.15.1"` — verified via GitHub API this is the current latest release/tag (published 2022-07-31, no newer tags since). `Package.resolved` confirms the exact pin; PathKit (1.0.1) rides along transitively as Stencil's own dependency, exactly per plan.md §5's dependency budget. (Spectre also resolves since it's Stencil's own test-only dependency, but is not linked by our targets.)
    - `.github/workflows/ci.yml` copied verbatim from FoundationModelsShelltool.
    - Added `Package.resolved` to `.gitignore`, matching the convention in nearly every sibling package (Shelltool, ACP, CodeContext, FileTool, MCP, MetadataRegistry, Multitool, OperationTool, Ranker, Router) — only AgentHarness commits it, and only because it pins a branch dependency, which doesn't apply here.

    Verification: `rm -rf .build && swift build` succeeds clean; `swift test` passes (1 test, 0 failures, 0 warnings).
  timestamp: 2026-07-19T13:09:42.329803+00:00
- actor: claude-code
  id: 01kxx84966kbgptbywey57a8s0
  text: |-
    really-done verification: fresh `swift build` and `swift test` both exit 0 (1 test, 0 failures, 0 warnings). Adversarial double-check agent independently reproduced every claim (Stencil 0.15.1 is genuinely latest, dependency graph is Stencil+PathKit+Spectre(test-only, unlinked) only, ci.yml byte-identical to Shelltool's, .v27 unavailability reproduced directly via compiler error, clean build/test with zero warnings, .gitignore convention checked across all siblings) — verdict PASS, no findings to address.

    Task is green and left in `doing` per /implement's process — ready for /review.
  timestamp: 2026-07-19T13:12:57.286558+00:00
position_column: done
position_ordinal: '80'
title: 'Scaffold package: Package.swift, targets, CI'
---
## What\nCreate the Swift package skeleton for FoundationModelsExtras, mirroring sibling conventions (see `../FoundationModelsShelltool/Package.swift`).\n\n- `Package.swift`: `// swift-tools-version: 6.2`, platform macOS 27 per plan.md (use `.macOS(.v27)`; if that enum case does not exist in tools 6.2, fall back to `.v26` like Shelltool and note it), library product `FoundationModelsExtras` from target at `Sources/FoundationModelsExtras`, test target `FoundationModelsExtrasTests` at `Tests/FoundationModelsExtrasTests` using swift-testing.\n- Dependency budget per plan.md §5: **Foundation + Stencil only** (PathKit rides along transitively). Add `https://github.com/stencilproject/Stencil.git` pinned with `exact:` to the current latest release. No Yams, no family imports.\n- A minimal placeholder source file (e.g. an empty enum with a doc comment) so the package builds, and one trivial swift-testing test so `swift test` runs.\n- `.github/workflows/ci.yml` mirroring Shelltool's verbatim: `uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` on push to main / pull_request / workflow_dispatch with the same concurrency group.\n- `.gitignore` for `.build/` etc. (copy a sibling's).\n\n## Acceptance Criteria\n- [x] `swift build` succeeds on a clean checkout\n- [x] `swift test` succeeds and runs at least one swift-testing test\n- [x] `Package.resolved` pins Stencil to an exact version\n- [x] `.github/workflows/ci.yml` matches the sibling pattern (reusable swift-ci workflow)\n- [x] No dependencies beyond Stencil (and its transitive PathKit) in Package.swift\n\n## Tests\n- [x] `Tests/FoundationModelsExtrasTests/SmokeTests.swift` — one trivial `@Test` proving the test target links against the library\n- [x] Run `swift test`; expect all tests pass, zero warnings\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.