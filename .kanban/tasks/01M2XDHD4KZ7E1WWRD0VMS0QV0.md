---
comments:
- actor: claude-code
  id: 01m2xgzqe9ssb7n74awvcjxhy6
  text: |-
    Picked up. Research findings:

    - The ten source files are in `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/` with 4-space indentation. The grant removal card in Skills has landed: `MarketplaceSource` has no `grants` field, and a grep over the ten files finds no `grants`, `RenderPolicy`, `allowed-tools` or `SkillsRegistry`. There is nothing to scrub.
    - `MarketplacePolicy.snapshotLimits` is typed `SnapshotLimits`. In Skills that type is in `SnapshotWriter.swift`, which card ^nqdcd57 moves. Without it the policy does not compile.
    - `MarketplaceIdentity.validate(_:)` returns `[MarketplaceDiagnostic]`. In Skills that type is in `MarketplaceDiagnostic.swift`, which card ^qtwjzx9 moves. Without it the identity file does not compile.
    - The env variable names `SKILLS_MARKETPLACE_CACHE` and `SKILLS_MARKETPLACE_SEED` and the path `.cache/skills/marketplaces` are statics of the Skills `MarketplaceCache`, not of `MarketplaceIdentity`. `MarketplaceIdentity` holds the pre-fetch key, the cache folder name and the list validation only.
    - `MarketplaceConfig.load(from:includeProject:)` reads `DotfolderStack.layers`, `Layer.source` and `Layer.root`. This package has all three, and the `Source` enum has the four cases `.defaults`, `.user`, `.project`, `.marketplace` that the loader switches over. The Skills `ConfigFixture` builds its stack with `DotfolderStack(name:workingDirectory:userDirectory:environment:)`, which this package has.
    - The Skills tests to move: `MarketplaceSourceTests.swift` (already without grants cases; it also holds the `validate` and `MarketplaceDiagnostic` cases), `SourcePatternTests.swift`, `MarketplaceConfigTests.swift`. The Skills `MarketplacePolicyTests.swift` runs through a store and a git fixture, thus it belongs to card ^qtwjzx9; this card writes the pure `MarketplacePolicyValueTests.swift` instead.
    - `MarketplaceConfigTests` calls `MarketplaceTestSupport.makeTempDirectory()` with no files, and `MarketplaceTestSupport.writeFile(text:to:)`. `FixtureSupport.TemporaryDirectory.make()` (from card ^jhj8kd2) replaces the first. No test calls `makeTempDirectory(withFiles:)` with files.
    - The tests of this package use `@Suite("...")`, `@Test`, 2-space indentation and `@testable import Marketplace`.
  timestamp: 2026-09-19T19:06:14.345688+00:00
- actor: claude-code
  id: 01m2xh04cbjnvdavqsr1x02et1
  text: |-
    Decisions:

    1. `SnapshotLimits` moves now, into `Sources/Marketplace/SnapshotLimits.swift`, with the same members. The policy names it in a stored property, thus the target does not build without it. Card ^nqdcd57 lists it under `SnapshotWriter.swift`; that card finds it here and leaves it in its own file. Same rule as card ^jhj8kd2 decision 1: move the smallest set of types that a moved file names.
    2. `MarketplaceDiagnostic` moves now, into `Sources/Marketplace/MarketplaceDiagnostic.swift`, with the same members. `MarketplaceIdentity.validate(_:)` returns it. Card ^qtwjzx9 lists it; that card finds it here. The `validate` tests and the two diagnostic description tests of the Skills `MarketplaceSourceTests` come with it.
    3. The env variable names `SKILLS_MARKETPLACE_CACHE` and `SKILLS_MARKETPLACE_SEED` and the default cache path are not in the Skills `MarketplaceIdentity`. This card moves `MarketplaceIdentity` as it is and renames nothing. The three host contracts come with `MarketplaceCache` on card ^nqdcd57, whose test list names "the location from the environment variable and the default". Moving those statics into `MarketplaceIdentity` here would be a redesign, and the cache card would then find them in the wrong type.
    4. Access levels stay as in Skills: `MarketplaceLocation`, `MarketplaceIdentity`, `MarketplaceSourceError`, `SourcePattern.matches(normalizedURL:)`, `MarketplacePolicy.refusal(forNormalizedURL:)` and `MarketplacePolicy.SourceRefusal` are internal. The tests reach them with `@testable import Marketplace`. The store, when card ^qtwjzx9 moves it, is in the same module.
    5. The doc comments of `MarketplacePolicy` keep their DocC links to `MarketplaceStore` and `MarketplaceEvent`. The compiler does not check a DocC link, and card ^qtwjzx9 brings both types. The card forbids only `RenderPolicy`, `allowed-tools` and `SkillsRegistry`.
    6. `Tests/MarketplaceTests/MarketplaceTestSupport.swift` gets an `enum MarketplaceTestSupport` with `writeFile(text:to:)` only. `makeTempDirectory(withFiles:)` is not moved: no test here gives it files, and the config fixture calls `TemporaryDirectory.make()` directly. An unused helper would be dead code.
    7. `MarketplaceConfigTests` imports `Marketplace` without `@testable`, because every type it names is public. That proves the public surface of the loader.
    8. One test file more than the card lists: `Tests/MarketplaceTests/MarketplacePinErrorTests.swift` proves the description of the moved `MarketplacePinError`, the same way card ^jhj8kd2 added `MarketplaceTimeoutErrorTests` for a type with no caller yet.
    9. The Skills assertion `config.marketplaces.count == 2` becomes a comparison with the whole two-entry list, because a bare `2` in a test is an unnamed numeric literal under `magic-numbers-swift`.

    TDD plan: RED: the six test files (five new, one changed) fail to compile because no moved type exists in `Marketplace`. GREEN: the twelve source files under `Sources/Marketplace/` with 2-space indentation.
  timestamp: 2026-09-19T19:06:27.595345+00:00
- actor: claude-code
  id: 01m2xhe87mnejjr5c5a4yvnkf7
  text: |-
    Implementation landed. Notes for the next agent:

    - TDD cycle: RED was `swift build --build-tests` with the five new test files and the changed `MarketplaceTestSupport.swift` in place and no moved source; the compiler stopped with `cannot find type 'MarketplacePinError' in scope` (exit 1). GREEN was the twelve source files under `Sources/Marketplace/`; the same build completes with no `warning:` line, and `swift test` passes.
    - The moved code is the Skills code with 2-space indentation and no other change, with two exceptions that keep the doc comments free of a consumer name: `SkillSelection` says "does not exist for the consumer" (Skills: "for the registry"), and the two `ApplyUpdates` docs and the `applyUpdates` docs of `MarketplacePolicy` say "the consumer" (Skills: "the registry"). Card ^qtwjzx9 §4 asks for that wording on the store; the same rule applied here so the later boundary test finds nothing.
    - Two lines of Skills were re-wrapped to keep the 2-space files under the line length: the `formDescription` literal of `SkillSelection`, and the duplicate-key message of `MarketplaceIdentity`. The text is the same.
    - `Tests/MarketplaceTests/MarketplaceTestSupport.swift`: the `writeFile(text:to:)` body is the same two Foundation calls as `MarketplaceConfig.save(to:)`. The helper stays separate on purpose: a fixture written with the code under test can pass while both are wrong, and the doc comment of the helper says so.
    - The `FoundationModelsSkills` working tree shows many changed files (README, CHANGELOG, `Render/`, `Resources/`, `ScriptProcessRunner.swift` deleted, and more). None of them is from this card: this card read that repository only, and wrote nothing there.
    - A grep over `Sources/Marketplace` for `RenderPolicy`, `allowed-tools`, `SkillsRegistry`, `SkillDiscovery`, `FrontmatterDecoder` and `grant` finds nothing.
    - Card text against the source, for the reviewer: the card says `MarketplaceIdentity` "keeps" `SKILLS_MARKETPLACE_CACHE`, `SKILLS_MARKETPLACE_SEED` and the default cache path. The Skills `MarketplaceIdentity` never held them; they are statics of the Skills `MarketplaceCache`, which card ^nqdcd57 moves (decision 3). Nothing was renamed, and nothing was moved into the wrong type.

    Test counts: `swift test` — 6 test bundles, 717 tests (125 + 34 + 44 + 26 + 121 + 367), 0 failures, 0 skipped. `MarketplaceTests`: 121 tests in 11 suites (was 61 in 6). The five new suites: "Marketplace source", "Source pattern", "Marketplace config", "Marketplace policy values", "Marketplace pin error".
  timestamp: 2026-09-19T19:14:10.292585+00:00
- actor: claude-code
  id: 01m2xhedkhhr217e0aq4kf7029
  text: |-
    ### implement — changed
    - evidence: 18 files. Modified: Tests/MarketplaceTests/MarketplaceTestSupport.swift. Added: Sources/Marketplace/MarketplaceSource.swift, Sources/Marketplace/SkillSelection.swift, Sources/Marketplace/SourcePattern.swift, Sources/Marketplace/MarketplaceLocation.swift, Sources/Marketplace/MarketplaceIdentity.swift, Sources/Marketplace/MarketplaceSourceError.swift, Sources/Marketplace/MarketplacePinError.swift, Sources/Marketplace/MarketplacePolicy.swift, Sources/Marketplace/MarketplaceConfig.swift, Sources/Marketplace/MarketplaceConfigError.swift, Sources/Marketplace/MarketplaceDiagnostic.swift, Sources/Marketplace/SnapshotLimits.swift, Tests/MarketplaceTests/MarketplaceSourceTests.swift, Tests/MarketplaceTests/SourcePatternTests.swift, Tests/MarketplaceTests/MarketplaceConfigTests.swift, Tests/MarketplaceTests/MarketplacePolicyValueTests.swift, Tests/MarketplaceTests/MarketplacePinErrorTests.swift. `swift build --build-tests`: exit 0, 0 warnings. `swift test`: 717 tests in 6 test bundles pass, 0 failures, 0 skipped (MarketplaceTests: 121 tests in 11 suites). No change in `FoundationModelsSkills`.
    - next: `/review` moves the card into review.
  timestamp: 2026-09-19T19:14:15.793470+00:00
- actor: claude-code
  id: 01m2xhm872x1p8sfabnb266dz8
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (full rebuild of the Marketplace target and its tests, forced with `touch`) — 0 warnings, 0 errors; `swift test` — 367 tests in 30 suites, 0 failed, 0 skipped
    - next: send the task to the review step.
  timestamp: 2026-09-19T19:17:26.882869+00:00
- actor: claude-code
  id: 01m2xhn5d1e78r744qnst5kteg
  text: |-
    ### commit — changed
    - evidence: 81c51f8 feat(marketplace): move the source model, the policy, and the config loader
    - next: Send the task on to review.
  timestamp: 2026-09-19T19:17:56.769059+00:00
- actor: claude-code
  id: 01m2xj1fj06tw74y8pa3sfw51h
  text: |-
    ### review — findings
    - evidence: 1 finding — Sources/Marketplace/SkillSelection.swift:39
    - next: Add the test that decodes a case variant of `all` and expects a `DecodingError`. Check the item in the `## Review Findings (2026-09-19 14:18)` section. Then run the review again on the new checkpoint.
  timestamp: 2026-09-19T19:24:40.384361+00:00
- actor: claude-code
  id: 01m2xj1tyvctpnzm765ar8e7tt
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 18 files
    - test: green — swift test, 717 passed, 0 failed, 0 skipped
    - commit: 81c51f8
    - review: findings — Sources/Marketplace/SkillSelection.swift:39 (case-sensitivity-coverage: no test that a case variant of `all` is refused)
  timestamp: 2026-09-19T19:24:52.059312+00:00
- actor: claude-code
  id: 01m2xj759h29kfrfpfksx9gzf1
  text: |-
    Picked up again for the one open review finding (`Sources/Marketplace/SkillSelection.swift:39` `completeness/case-sensitivity-coverage`).

    Research:
    - `SkillSelection.init(from:)` compares the string form with `text == Self.allValue`, and `allValue` is `"all"`. The doc comment of the type says the string form is `all`, thus the case-sensitive comparison is the contract.
    - `Tests/MarketplaceTests/MarketplaceSourceTests.swift` has `anUnknownSkillSelectionDoesNotDecode`, a parameterized test over `"some"`, `{"teams": ["a"]}` and a two-key map. No argument is a case variant of `all`.
    - The `case-sensitivity-coverage` rule asks for one test that feeds the non-canonical spelling through the changed path, not a battery of spellings and not a test for each token position. The map keys `plugins` and `skills` go through `CodingKeys`, a different comparison; the finding names the `all` comparison only, so one test for `"All"` is the whole fix.

    Decision:
    1. Add `aCaseVariantOfAllDoesNotDecode` to the "Marketplace source" suite, in the form the finding gives, after `anUnknownSkillSelectionDoesNotDecode`. A named test makes the contract visible in the test name. The `"All"` literal is not added to the parameterized invalid-input test, because there it would read as one more unknown string, not as the case contract.
    2. TDD: the production code already refuses `"All"`, so the test passes at once. To prove the test can fail, RED is a temporary `text.lowercased() == Self.allValue` in `SkillSelection`, which the test must catch. The temporary change is reverted before GREEN. No production code changes in the end.
  timestamp: 2026-09-19T19:27:46.481200+00:00
- actor: claude-code
  id: 01m2xjaw308fzph083nq285dks
  text: |-
    Finding worked: `Sources/Marketplace/SkillSelection.swift:39` `completeness/case-sensitivity-coverage`, checked in the `## Review Findings (2026-09-19 14:18)` section.

    - Added `aCaseVariantOfAllDoesNotDecode` to `Tests/MarketplaceTests/MarketplaceSourceTests.swift`, after `anUnknownSkillSelectionDoesNotDecode`, in the form the finding gives: `#expect(throws: DecodingError.self)` over `decode(SkillSelection.self, from: #""All""#)`.
    - TDD: RED was `swift test --filter aCaseVariantOfAllDoesNotDecode` with a temporary `text.lowercased() == Self.allValue` in `SkillSelection.init(from:)`; the test failed with "an error was expected but none was thrown and "all" was returned" (exit 1). The temporary change was reverted; `git status` shows no change under `Sources/`. GREEN: the same test passes against the committed comparison.
    - No production code changed. The comparison `text == Self.allValue` stays as it is, because the doc comment names the string `all` as the contract.

    ### implement — changed
    - evidence: 1 file — Tests/MarketplaceTests/MarketplaceSourceTests.swift (one test added, `aCaseVariantOfAllDoesNotDecode`). `swift build --build-tests`: 0 warnings. `swift test`: 367 tests in 30 suites passed, 0 failures. RED proven with a temporary case-insensitive comparison, then reverted.
    - next: `/review` runs again on the new checkpoint and moves the card into review.
  timestamp: 2026-09-19T19:29:48.128884+00:00
- actor: claude-code
  id: 01m2xjep887ykghxvx97ezyva2
  text: |-
    ### test — green
    - evidence: swift build --build-tests (0 warnings, build complete); swift test — 367 tests, 30 suites, 0 failed, 0 skipped
    - next: none. The build is clean.
  timestamp: 2026-09-19T19:31:53.224221+00:00
depends_on:
- 01M2XDH57XW45Z6W0V3JHJ8KD2
position_column: doing
position_ordinal: '80'
title: Move the marketplace source model, the policy and the config loader
---
## What

In the `Marketplace` target that the transport card added, move the pure value types of a marketplace source, the policy, and the `marketplaces.yaml` loader. These files do no git work and no snapshot work.

The grant removal card on the `FoundationModelsSkills` board (`^8mxhn6a` on that board) lands first, so `MarketplaceSource` arrives with no `grants` field and there is no `MarketplaceGrants` type. If that card is not done yet when this card starts, remove the grants here and do not carry them over.

1. Move these files from `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/` into `Sources/Marketplace/`, with 2-space indentation and the same type names: `MarketplaceSource.swift` (`MarketplaceSource` only), `SkillSelection.swift`, `SourcePattern.swift`, `MarketplaceLocation.swift`, `MarketplaceIdentity.swift` (it imports `CryptoKit`), `MarketplaceSourceError.swift`, `MarketplacePinError.swift`, `MarketplacePolicy.swift`, `MarketplaceConfig.swift`, `MarketplaceConfigError.swift`.
2. `MarketplaceConfig` keeps `load(from:includeProject:)` over a `DotfolderStack` and `save(to:)`. It reads the `.user` and `.project` layers only. It keeps Yams for the decode and the encode; the target declares that dependency.
3. `MarketplaceIdentity` keeps the env variable names `SKILLS_MARKETPLACE_CACHE` and `SKILLS_MARKETPLACE_SEED`, and the default cache path under `~/.cache/skills/marketplaces`. These are documented host contracts; a rename is not part of the move.
4. Move the tests: `MarketplaceSourceTests.swift` (without the grants cases), `SourcePatternTests.swift`, `MarketplaceConfigTests.swift` into `Tests/MarketplaceTests/`. `MarketplaceConfigTests` builds its stack from a temporary directory; take the temporary directory helper from `FixtureSupport`. Move `makeTempDirectory(withFiles:)` and `writeFile(text:to:)` of the Skills `MarketplaceTestSupport` into `Tests/MarketplaceTests/MarketplaceTestSupport.swift` if the tests need them.
5. Scrub the doc comments of the moved files: no comment names `RenderPolicy`, `allowed-tools` or `SkillsRegistry`. The doc of `MarketplaceSource` in Skills names the first two; a later card adds a boundary test over the whole target that fails on those names.
6. Do not delete anything in `FoundationModelsSkills`.

## Acceptance Criteria

- [ ] Every §5.1 source form of the Skills `marketplace.md` parses to the same `MarketplaceLocation` here as in Skills: HTTPS `.git`, `github:owner/repo`, `#ref` suffix, `file://`, and the scp-like SSH form (accepted by the parser, refused by the transport).
- [ ] `MarketplacePolicy` refuses a source by the allowlist and the blocklist before any I/O, and reads `SKILLS_MARKETPLACE_AUTOUPDATE` from its environment.
- [ ] `MarketplaceConfig.load(from:includeProject:)` merges the user list and the project list with the alias-or-URL merge key, and `save(to:)` writes a file that loads back equal.
- [ ] No type in `Sources/Marketplace` names a grant, and no doc comment of the moved files names `RenderPolicy`, `allowed-tools` or `SkillsRegistry`.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/MarketplaceTests/MarketplaceSourceTests.swift`: the URL forms, the identity rules (pre-fetch key from alias or repository name), `SkillSelection` decode of `all`, `plugins:` and `skills:`, and each `MarketplaceSourceError` case.
- [ ] `Tests/MarketplaceTests/SourcePatternTests.swift`: the match table of `.owner`, `.repository` and `.prefix` over the normalized URL.
- [ ] `Tests/MarketplaceTests/MarketplaceConfigTests.swift`: a project entry with the same key replaces the user entry in the project position; `includeProject: false` reads the user file only; a `grants:` key in an entry is ignored; save then load gives an equal value.
- [ ] `Tests/MarketplaceTests/MarketplacePolicyValueTests.swift`: the allowlist and the blocklist decide with no store and no I/O.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#marketplace #cross-repo

## Review Findings (2026-09-19 14:18)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 18 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/Marketplace/SkillSelection.swift:39` `completeness/case-sensitivity-coverage` — The comparison `text == Self.allValue` performs case-sensitive matching against "all", which correctly enforces the format specification (documented at line 7-8 as "the string `all`"), but no test explicitly verifies that case variants like "All" or "ALL" are rejected. The existing invalid-input tests use entirely different strings rather than case variants. Add one test that explicitly feeds a case variant through the decode path: `@Test func aCaseVariantOfAllDoesNotDecode() { #expect(throws: DecodingError.self) { try decode(SkillSelection.self, from: #""All""#) } }`.
