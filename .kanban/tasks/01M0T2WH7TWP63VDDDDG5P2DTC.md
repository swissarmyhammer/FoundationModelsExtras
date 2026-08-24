---
comments:
- actor: claude-code
  id: 01m0t41rwntpp4k909d7prmges
  text: |-
    Picked up. Research done.

    Baseline before any change: `swift test` = 229 tests in 21 suites, all pass, exit 0.

    What the code shows:
    - `Package.swift:16` is `.macOS(.v26)`, and the comment above it says the fallback matches `FoundationModelsShelltool`'s manifest. That claim is false: `FoundationModelsShelltool/Package.swift:12` writes `.macOS("27.0")`.
    - `PackageRootValidation.requireWithinPackageRoot` has exactly ONE caller: `DocCoverageTests.swift:86`. Confirmed by grep over the whole package. So it becomes dead code the moment the doc-coverage files go.
    - `PackageRootValidation.packageRoot()` has three callers that stay: `ExtrasDemoIntegrationTests.swift:53`, `IgnoreGitParityTests.swift:121`, `CorpusGoldenTests.swift:49`.
    - `rg -in shelltool Package.swift Tests` finds 11 matches before the change. 6 go with the two deleted files and the deleted `swift-syntax` block; 5 more need a rewrite (Package.swift lines 13, 71, 93-94; ExtrasDemoIntegrationTests lines 3 and 23; PackageRootValidation line 7). The Yams comment at Package.swift:34 stays, per the card.
    - The enum doc comment on `PackageRootValidation` describes the path-containment guard alone, so it has to be rewritten when that guard goes, not just trimmed.

    Validator rules read for `.swift`: code-hygiene, code-security, completeness, duplication, reuse, swift, test-integrity (55 rules).
  timestamp: 2026-08-24T14:51:02.933084+00:00
- actor: claude-code
  id: 01m0t48j000mn0y80kw7xkt8gq
  text: |-
    Implementation landed. All three changes of the card are in, and every acceptance criterion is verified rather than assumed.

    Verification, each run after the change:
    - `swift package dump-package` reports `platforms: [{platformName: macos, version: 27.0}]`, and its dependency list is Stencil, Yams and swift-argument-parser only.
    - `rg -in shelltool Package.swift Tests` finds ONE match: `Package.swift:33`, the Yams comment the card keeps.
    - `rg -n "DocCoverage|requireWithinPackageRoot|SwiftSyntax|SwiftParser|swift-syntax" .` over the whole package finds nothing.
    - Clean rebuild (`rm -rf .build && swift build`): exit 0, zero warnings, zero errors. It fetches PathKit, Stencil, Spectre, swift-argument-parser and Yams, and no swift-syntax.
    - `swift test`: 214 tests in 19 suites pass, exit 0. `ExtrasDemoIntegrationTests`, `IgnoreGitParityTests` and `CorpusGoldenTests` each pass, which is what proves `packageRoot()` still works with `requireWithinPackageRoot` gone.
    - No new test was written.

    Two things the next agent should know:

    1. **`Package.resolved` is gitignored** (`.gitignore:11`), so it is untracked and the change shows NO diff for it. The card's criterion is still met: the file on disk holds no `swift-syntax` entry after `swift package resolve`. Do not go looking for that file in the commit.

    2. **The `PackageRootValidation` doc comment needed a rewrite, not a trim.** Its first sentence described the path-containment guard alone ("Shared path-containment guard for tests that resolve a relative path against the package root and must reject paths that escape it via `..`"). With `requireWithinPackageRoot` deleted, that sentence described nothing the file holds, so it now reads "Shared package-root lookup for tests that read a checked-in file off disk instead of through `Bundle.module`." The enum KEEPS its name, because the card names `PackageRootValidation.packageRoot()` as the call the three surviving tests make; renaming the enum is out of scope for this card.

    Test count moved 229 -> 214, and suite count 21 -> 19. That is exactly the 13 tests of `DocCoverageScannerTests` plus the 2 of `DocCoverageTests`. No other test was lost.

    `swift format -i -r Sources Tests` ran and changed nothing. `Package.swift` sits outside that command's scope and keeps its own 4-space manifest indentation.

    ### implement — changed
    - evidence: 5 files — Package.swift, Tests/FoundationModelsExtrasTests/DocCoverageTests.swift (deleted), Tests/FoundationModelsExtrasTests/DocCoverageScannerTests.swift (deleted), Tests/FoundationModelsExtrasTests/PackageRootValidation.swift, Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift. 12 insertions, 464 deletions. `swift build` exit 0 with zero warnings; `swift test` 214/214 pass in 19 suites.
    - next: /review
  timestamp: 2026-08-24T14:54:45.248253+00:00
position_column: doing
position_ordinal: '80'
title: Remove doc-coverage lint tests, drop swift-syntax, target macOS 27
---
## What

`FoundationModelsExtras` is the leaf package of the family. It has no code
dependency on `FoundationModelsShelltool`. But its manifest and its tests copy
conventions from Shelltool and name Shelltool in comments. This points the wrong
way: a low-level package must not cite a package above it. One of these comments
is already incorrect.

Make three changes in `FoundationModelsExtras`.

### 1. Set the platform to macOS 27

`Package.swift:16` declares `.macOS(.v26)`. The comment at `Package.swift:8-14`
says the family targets macOS 27+, and that `.v26` is a fallback because `.v27`
needs `PackageDescription` 6.4. The comment also says this is the "same as
`FoundationModelsShelltool`'s `Package.swift`". That is not true.
`FoundationModelsShelltool/Package.swift:12` declares `.macOS("27.0")` — the
string form, which gives macOS 27 with tools-version 6.2.

Use the string form here:

```swift
platforms: [
    .macOS("27.0"),
],
```

Delete the "pending a tools-version bump" text and the Shelltool sentence.

### 2. Delete the doc-coverage tests

These tests parse the source of this package with SwiftSyntax. They fail the
build if a `public` declaration has no documentation comment. This is a lint
rule, not a test of behavior. Delete these two files:

- `Tests/FoundationModelsExtrasTests/DocCoverageTests.swift`
- `Tests/FoundationModelsExtrasTests/DocCoverageScannerTests.swift`

Then remove what only these two files used:

- the `swift-syntax` dependency at `Package.swift:47`, and its comment at
  `Package.swift:40-46`
- the `SwiftSyntax` and `SwiftParser` products at `Package.swift:98-99`, and
  their comment at `Package.swift:96-97`
- `PackageRootValidation.requireWithinPackageRoot` at
  `Tests/FoundationModelsExtrasTests/PackageRootValidation.swift:40`.
  `DocCoverageTests.swift:86` is its only caller.

Keep `PackageRootValidation.packageRoot()`. Three other tests call it:
`ExtrasDemoIntegrationTests.swift:53`, `IgnoreGitParityTests.swift:121`, and
`CorpusGoldenTests.swift:49`.

### 3. Remove the remaining upward citations

Write each convention as a rule of this package. Do not name a sibling package.

- `Package.swift:71` — "mirroring `FoundationModelsShelltool`'s `shell-demo`
  example layout"
- `Package.swift:93-94` — "Mirrors `FoundationModelsShelltool`'s
  `ShellToolTests` -> `shell-demo` dependency"
- `Tests/FoundationModelsExtrasTests/ExtrasDemoIntegrationTests.swift:3` and
  `:23`
- `Tests/FoundationModelsExtrasTests/PackageRootValidation.swift:6-8`. Also
  delete the "Used by `DocCoverageTests`" sentence there.

Keep one reference: the Yams comment at `Package.swift:31-38`. It names
Shelltool's `ShellPolicy` as one of three consumers that made Yams necessary.
This is a record of a decision, not a copied convention. `plan.md` keeps the
same record.

## Acceptance Criteria

- [x] `Package.swift` declares `.macOS("27.0")`.
- [x] `DocCoverageTests.swift` and `DocCoverageScannerTests.swift` do not exist.
- [x] `Package.swift` has no `swift-syntax` dependency, no `SwiftSyntax`
      product, and no `SwiftParser` product.
- [x] `Package.resolved` has no `swift-syntax` entry.
- [x] `requireWithinPackageRoot` does not exist. `packageRoot()` stays.
- [x] `rg -i shelltool Package.swift Tests` finds one match only: the Yams
      comment in `Package.swift`.

## Tests

- [x] Run `swift test` before you change anything. Record the result. This is
      the baseline.
- [x] Run `swift build` after the change. It must succeed with the macOS 27.0
      deployment target.
- [x] Run `swift test` after the change. Every remaining test must pass. The
      output must not contain `DocCoverage`.
- [x] `ExtrasDemoIntegrationTests`, `CorpusGoldenTests`, and
      `IgnoreGitParityTests` must pass. These tests call
      `PackageRootValidation.packageRoot()`. They prove the helper still works
      after you remove `requireWithinPackageRoot`.
- [x] Run `swift package resolve`. Then run `rg -n "swift-syntax"
      Package.resolved`. It must find nothing.
- [x] Do not write a new test to replace the doc-coverage scan. This task
      removes a source-parsing lint. Do not add a different one.

## Workflow

- This task removes tests and adds none. `/tdd` does not apply, because there is
  no new behavior to specify first.
- Run the test suite before the change to get a green baseline. Make the
  changes. Then run `swift build` and `swift test` again and compare.