---
comments:
- actor: claude-code
  id: 01m2xtbtfnk3vb94gbjfya9pt8
  text: |-
    ### finish — note on the push criterion
    - The finish loop commits a local checkpoint on each iteration and never pushes. The push to `main` is the step of the user after the loop.
    - next: the user pushes `main` after this card is in `done`.
  timestamp: 2026-09-19T21:50:07.861430+00:00
- actor: claude-code
  id: 01m2xtk0y34srykkwjtg6wb9qr
  text: |-
    Picked up. Research findings:

    - The three documents have the shape the card names. `README.md` has one section for each capability (`IgnoreProcessor`, `Doctorable`, `ProcessRunner`) before `## Install`, each with one fenced example and one paragraph that names the test that mirrors it. The lead paragraph lists the four original pillars only. `CHANGELOG.md` has `## Unreleased` with the `ProcessRunner` entry at the top: an opening paragraph with the API, **Cause.**, **What changed.** with one bullet for each public type. `plan.md` ends at `## 11.`; §5 holds the dependency budget with one parenthetical for each addition (`ProcessRegistry`, `ProcessRunner`), and §6 is a table of consumers.
    - The existing README contract tests (`readmeGitignoreAndReviewignoreCombinationExample`, `readmeExitCodeAndMergedOutputExample`) are hand-mirrored copies. `Examples/NotesTool/Tests/NotesToolTests/ReadmeSnippetTests.swift` is the one text-equality test of the package: it parses fenced blocks out of `docs/GUIDE.md` and compares them line by line, with the leading and trailing whitespace of each line removed, against a source file. The card asks for the text-equality shape for the marketplace example.
    - The public surface of the `Marketplace` target, from the sources: `MarketplaceStore` (`init(sources:layout:cacheDirectory:policy:)`, `init(...transport:clock:environment:)`, `cacheDirectory(environment:)`, `marketplaceLayers()`, `layerUpdates`, `events`, `diagnostics`, `start()`, `stop()`, `check()`, `update(_:force:)`, `pin(_:sha:)`, `unpin(_:)`), `MarketplaceLayerProviding`, `MarketplaceLayer` (`layer`, `provenance`, `isWatchable`), `MarketplaceProvenance` (`displayText`), `MarketplaceSource` (`url`, `ref`, `sha`, `path`, `alias`, `select`, `autoUpdate`; no `grants`), `SkillSelection`, `SourcePattern`, `MarketplacePolicy`, `SnapshotLimits`, `MarketplaceCredential`, `MarketplaceConfig` (`fileName`, `load(from:includeProject:)`, `save(to:)`), `MarketplaceConfigError`, `MarketplaceLayout` (`documentName`, `excludedDirectoryNames`, `partialsDirectoryName`), `MarketplaceEvent`, `MarketplaceStatus`, `MarketplaceDiagnostic`, `MarketplacePinError`, `GitTransport`, `GitTransportError`, `LibGit2Transport`. The cache, the state file, the catalog types, the resolver and the snapshot writer are internal.
    - `DotfolderStack.layers` is a public `var`, thus a host inserts the marketplace layers at index 0. `DotfolderStack.Source.marketplace` exists in the core target, and its doc says the layer is never trusted and that `init(name:workingDirectory:...)` never derives it.
    - `MarketplaceStoreFixture` and `GitFixtureRepository` are public in `MarketplaceFixtures`. The store tests read a layer root with `String(contentsOf:)`; no test reads a marketplace layer through a `DotfolderStack` yet.
    - `README.md` matches no validator. The 60 Swift rules are in one 754 K file; a subagent digest is in progress.
  timestamp: 2026-09-19T21:54:03.843540+00:00
- actor: claude-code
  id: 01m2xv3dsm4bxy1kt4rvg4y9n1
  text: |-
    Decisions:

    1. The README example is real code in `theExampleReadsAMarketplaceSkillThroughTheStack`, between the marker comments `// README example: begin` and `// README example: end`. The second test reads this file with `#filePath` and `README.md` with `FixtureFile`, cuts the fenced Swift block under the section heading and the lines between the markers, and compares them line for line with the leading and trailing whitespace removed. The README indents with 4 spaces and the test with 2, thus the comparison ignores indentation; the text is otherwise the same. This is the text-equality shape of `Examples/NotesTool/Tests/NotesToolTests/ReadmeSnippetTests.swift`, reduced to one block.
    2. The example names four inputs and not literals: `marketplaceURL`, `cacheDirectory`, `workingDirectory` and `userDirectory`. The README prose says what each one is. The test binds the URL to a `GitFixtureRepository` and the three folders to one temporary folder. `userDirectory` is in the example because `DotfolderStack.init(name:workingDirectory:)` derives the user layer from the real home directory, and a host with `~/.config/myagent/review/SKILL.md` would change the result of the test; the ProcessRunner README makes the same trade with its private registry.
    3. The example shows `cacheDirectory:` and not the default, for the same reason: the default is the real cache of the user. The prose names the default and its environment variable.
    4. The fixture skill is `review` with the body `Read the diff first.`, not the `alpha` of the store suites, because the README reads better with a real skill name. The two literals are also `static let` constants of the test for the fixture commit and the assertions; the block itself holds them as literals because the block is the README text.
    5. The README block reads the file with `stack.item(at:)`, thus the assertions prove both the winning layer source (`.marketplace`) and the text. `stack.layers.insert(contentsOf:at: 0)` inserts every marketplace layer at the bottom in list order.
    6. The README paragraph on trust says the layer source is `DotfolderStack.Source.marketplace`, "which is never trusted", the sentence of the core type doc. It does not name a mechanism that the core target does not have.
    7. `MarketplaceTestSupport` gets `readmePath` and `readmeMarketplaceHeading`, because `ReadmeSnippetTests` and `DocumentationTests` both read them, and a copy in each file is a duplicate.
    8. `DocumentationTests.theChangelogEntryIsTheFirstUnderUnreleased` proves the position, not only the presence: the first `### ` line after `## Unreleased` is the marketplace heading. `thePlanHoldsThePillarSectionWithTheDecisionDate` proves that the date is in the text from the `## 12.` heading onward, not anywhere in the plan. The grant guard is one parameterized test over the three documents.
    9. `plan.md`: the header status line names pillar 6 and the `Updated` date is 2026-09-19; the `FoundationModelsSkills` row of §6 loses its `(plan-only)` mark and names the consumer role; the §5 addition is one parenthetical in the dependency-budget bullet, in the shape of the `ProcessRegistry` and `ProcessRunner` ones. Yams is already in the core budget, thus §5 says that the `Marketplace` target depends on Yams directly for `marketplaces.yaml` and that the core target keeps Yams inside `YAMLValue.swift`; it does not claim that Yams is new.
    10. `README.md`: the `## Documentation` line says "all six pillars" in place of "all four pillars", because it names `plan.md`, which now has six.
    11. The three documents use the word "grant" only to say that there is none (`no grant`, `no grants field`, `grants anything`), as the card orders. The guarded string is the type name `MarketplaceGrants`, which no document holds.
    12. Lint: `swiftlint --enable-all-rules` on the two new files reports none of the rules that the review enforces (`no_magic_numbers`, `missing_docs`, the force rules, the length rules, `no_file_literal` and the others). `swift format lint --strict` reports `LineLength` only, a layout tag that the `idioms-swift` gate drops; the longest new line is within the width of the existing marketplace tests.

    TDD: RED was `swift test --filter 'ReadmeSnippetTests|DocumentationTests'` with the tests in place and the documents unchanged: `theReadmeHoldsTheMarketplaceSection`, `thePlanHoldsThePillarSectionWithTheDecisionDate`, `theChangelogEntryIsTheFirstUnderUnreleased` and `theReadmeBlockAndTheTestCopyAreTheSameText` failed (4 issues, exit 1); `theExampleReadsAMarketplaceSkillThroughTheStack` passed, which proves the example runs. GREEN is the three documents: the same filter passes 6 tests in 2 suites.
  timestamp: 2026-09-19T22:03:01.300015+00:00
- actor: claude-code
  id: 01m2xv3p9cza96jb0ckbtn0dys
  text: |-
    ### implement — changed
    - evidence: 6 files. Modified: README.md (lead paragraph, new section `## Remote layers: \`MarketplaceStore\`` before `## Install`, the `## Documentation` line), plan.md (header status and date, §5 dependency budget, §6 consumer row, new §12), CHANGELOG.md (`### Added: the \`Marketplace\` product` at the top of `## Unreleased`), Tests/MarketplaceTests/MarketplaceTestSupport.swift (`readmePath`, `readmeMarketplaceHeading`). Added: Tests/MarketplaceTests/ReadmeSnippetTests.swift, Tests/MarketplaceTests/DocumentationTests.swift. RED: `swift test --filter 'ReadmeSnippetTests|DocumentationTests'` failed with 4 issues (the three document tests and the text-equality test), exit 1. GREEN: the same filter passes 6 tests in 2 suites; `swift build --build-tests` exit 0 with no `warning:` line; `swift test` passes 936 tests in 6 bundles (125 + 34 + 44 + 26 + 332 + 375), 0 failures, 0 skipped. swiftlint reports none of the enforced rules on the new files. No change in FoundationModelsSkills. Not committed, not pushed.
    - next: `/review` moves the card into review. The finish loop commits; the user pushes `main`.
  timestamp: 2026-09-19T22:03:09.996172+00:00
- actor: claude-code
  id: 01m2xv8gqay7t67g4z7apgfpbp
  text: |-
    ### test — green
    - evidence: swift build --build-tests — 0 errors, 0 warnings; swift test — 375 tests in 30 suites passed, 0 failed, 0 skipped
    - next: send the task to review.
  timestamp: 2026-09-19T22:05:48.138794+00:00
- actor: claude-code
  id: 01m2xva6kvh3b19jw9jkfv99ka
  text: |-
    ### commit — changed
    - evidence: 7404f57 docs(marketplace): add the Marketplace pillar to README, plan.md, and CHANGELOG
    - next: send the commit for review. The user pushes main.
  timestamp: 2026-09-19T22:06:43.323094+00:00
- actor: claude-code
  id: 01m2xvjjkhwymsza3jz7t2nbf9
  text: |-
    ### review — findings
    - evidence: 1 finding — Tests/MarketplaceTests/DocumentationTests.swift:61 (swift/optionals)
    - next: Unwrap `firstEntry` with `try #require(...)` at the assignment in DocumentationTests.swift. Remove the same cause from the whole file. Then run `swift test` and start the review again with `HEAD~1..HEAD`.
  timestamp: 2026-09-19T22:11:17.745095+00:00
- actor: claude-code
  id: 01m2xvk40hk1k7n451xwa6tyz3
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files
    - test: green — swift test, 375 passed in 30 suites, 0 failed, 0 skipped
    - commit: 7404f57
    - review: findings — Tests/MarketplaceTests/DocumentationTests.swift:61 (swift/optionals: unwrap `firstEntry` with `#require` at the assignment)
  timestamp: 2026-09-19T22:11:35.569585+00:00
- actor: claude-code
  id: 01m2xvrvkp61ptwqf01r1dvhmn
  text: |-
    Picked up again for the one open review finding (`swift/optionals` in `Tests/MarketplaceTests/DocumentationTests.swift`).

    Discoveries:
    - The file holds three optionals. `section` and `unreleased` already unwrap with `try #require`. `firstEntry` was the one optional that an expectation compared directly. After the change, no optional in the file goes into an expectation.
    - The rule `optionals.md` of the `swift` validator says: unwrap with an assertion in a test (`try #require(source)`), never with `guard` or with a trailing `if let`. The change obeys it.
    - No production code changes. The test still proves the same thing, and it fails with a clear "required value is nil" message when no entry heading follows `## Unreleased`.
    - No `ARCHITECTURE.md` exists in the package.
    - No change in FoundationModelsSkills. No commit, no push, no worktree.
  timestamp: 2026-09-19T22:14:43.574870+00:00
- actor: claude-code
  id: 01m2xvs4hb46qjkq654yce55gz
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/MarketplaceTests/DocumentationTests.swift. `firstEntry` now unwraps with `try #require(...)` at the assignment; the expectation compares the unwrapped string. No other optional in the file goes into an expectation. The finding is checked on the card. `swift test --filter DocumentationTests`: 4 tests in 1 suite passed. `swift build --build-tests`: exit 0, 0 `warning:` lines. `swift test`: 936 tests in 6 bundles passed (125 + 34 + 44 + 26 + 332 + 375), 0 failures, 0 skipped. Not committed, not pushed.
    - next: `/review` with `HEAD~1..HEAD` plus the working tree. The finish loop commits; the user pushes `main`.
  timestamp: 2026-09-19T22:14:52.715416+00:00
- actor: claude-code
  id: 01m2xvx013peb8mx5f2gn60tt0
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` — 0 warnings, build complete; `swift test` — 375 tests in 30 suites passed, 0 failed, 0 skipped
    - next: hand off to review
  timestamp: 2026-09-19T22:16:59.171698+00:00
- actor: claude-code
  id: 01m2xvxvcj2xfh6dcyqnsw73zb
  text: |-
    ### commit — changed
    - evidence: 6d1ed60 fix(marketplace-tests): unwrap firstEntry with #require in DocumentationTests
    - next: send the task to the next pipeline step.
  timestamp: 2026-09-19T22:17:27.186025+00:00
- actor: claude-code
  id: 01m2xvzp87fm1vr5ft5s06yc12
  text: |-
    ### review — clean
    - evidence: 0 findings — `review sha HEAD~1..HEAD` (commit 6d1ed60), 1 file reviewed, 2 files not reviewed (`.kanban/` ignore rule). The one prior finding of 2026-09-19 17:07 is checked.
    - next: none. The task is in `done`.
  timestamp: 2026-09-19T22:18:27.463681+00:00
- actor: claude-code
  id: 01m2xw0424t1f2gh8x2d1qy4s8
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file, the finding of 2026-09-19 17:07 checked
    - test: green — swift test, 375 passed in 30 suites, 0 failed, 0 skipped
    - commit: 6d1ed60
    - review: clean — 0 findings, task moved to done
    - note: the push criterion stays with the user after the loop
  timestamp: 2026-09-19T22:18:41.604052+00:00
depends_on:
- 01M2XDHRDADTN57M8EVQTWJZX9
position_column: done
position_ordinal: b180
title: Document the Marketplace pillar in README, plan.md and CHANGELOG
---
## What

Record the new `Marketplace` product in the three documents that describe the package, in the shape the earlier capabilities used (`IgnoreProcessor`, `Doctorable`, `ProcessRunner`).

1. `README.md`: add a section `## Remote layers: \`MarketplaceStore\`` before `## Install`, with a short runnable example: make a `MarketplaceStore` from one `MarketplaceSource`, give it a `MarketplaceLayout`, call `marketplaceLayers()`, insert each layer at the bottom of a `DotfolderStack`, and read one file through the stack. Add the marketplace to the capability list in the lead paragraph. State in one line that a marketplace layer always renders untrusted and that there is no per-marketplace permission.
2. `plan.md`: append `## 12. Pillar 6 — Marketplace (a fetched, cached, materialized layer root)`. State the decision of 2026-09-19 (the user: Extras owns all marketplace file reading; a consumer reads a materialized root like a local layer), the split (transport, catalog, cache, writer, store, config here; the registry, the diagnostics provenance and the CLI in the consumer), the `MarketplaceLayout` inputs, and the "no grant" rule. In §5, extend the dependency budget: `swift-libgit2` (`exact: "1.9.7"`) and Yams on the separate `Marketplace` target only, never on the core target, with the reason. In §6, add `FoundationModelsSkills` as the consumer of `Marketplace`.
3. `CHANGELOG.md`: add `### Added: the \`Marketplace\` product` at the top of `## Unreleased`, in the shape of the `ProcessRunner` entry: the opening paragraph with the API, **Cause.** (the capability leaves `FoundationModelsSkills`, and why), **What changed.** with each public type. State that `MarketplaceSource` has no `grants` field.
4. The README example is contract-tested, the same as the `ProcessRunner` example: put the example text in a test and compile it.

## Acceptance Criteria

- [ ] `README.md` has the new section, and its example compiles and runs in a test.
- [ ] `plan.md` §12 names the decision date, the split, `MarketplaceLayout`, and the "no grant" rule; §5 names the libgit2 and Yams budget for the `Marketplace` target; §6 names the consumer.
- [ ] `CHANGELOG.md` has the entry at the top of `## Unreleased`.
- [ ] No document in this package names a marketplace grant.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.
- [ ] The work is committed and pushed to `main` of this repository.

## Tests

- [ ] `Tests/MarketplaceTests/ReadmeSnippetTests.swift`: the README example text and the test copy are the same text, and the example builds a store over a `GitFixtureRepository` and reads one file through the stack.
- [ ] `Tests/MarketplaceTests/DocumentationTests.swift`: `README.md` holds the section heading, `plan.md` holds the `## 12.` heading and the string `2026-09-19`, `CHANGELOG.md` holds the entry heading, and none of the three holds the string `MarketplaceGrants`.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#marketplace #docs

## Review Findings (2026-09-19 17:07)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 7 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 3 file(s) not reviewed — no validator matched:
> - `CHANGELOG.md` — no validator matches this file
> - `README.md` — no validator matches this file
> - `plan.md` — no validator matches this file

- [x] `Tests/MarketplaceTests/DocumentationTests.swift:61` `swift/optionals` — The optional `firstEntry` should be unwrapped with `#require` at the assignment, not compared directly in an expectation. This gives a confusing failure message (nil ≠ expected string) if no line starts with the entry heading prefix, rather than the clear failure that an assertion unwrap would give. Change line 61 to unwrap the optional: `let firstEntry = try #require(lines[unreleased...].first { $0.hasPrefix(Self.entryHeadingPrefix) })`, then keep line 63's expectation as-is to compare the unwrapped string to the expected heading.
