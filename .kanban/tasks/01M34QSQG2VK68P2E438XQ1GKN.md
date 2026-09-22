---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34qycjm1a2bv1gs07a0d8n5
  text: |-
    Research: `SnapshotWriter.write` calls `copyPartials(ofSourceRoots:)`, then `copyPartials(ofSkills:besides:)`. Only these call them. A `ResolvedSkill` has no source root. `CatalogPath.normalized` refuses `..`, so a listed skill is always below its plugin source. The plan: the owner root of a skill is the longest source root that is an ancestor of the skill path. A hand-built catalog with no such root walks from the tree root. The folder list is in catalog order, with each folder one time. The copy goes one level (component count) at a time, and it forgets the partials writes after each level.

    RED: aNestedSkillGetsThePartialsOfEachFolderFromTheSourceRootDown, eachPartialsFolderOfANestedSkillIsCopiedOneTime (5 files, not 7), and theMostSpecificCopyWinsWhenTheCatalogListsTheLessSpecificFolderLast (a diagnostic, and "from skills") fail. twoFoldersAtTheSameLevelGiveOneDiagnosticAndTheLaterFolderWins passes already, because the current code gives this behavior. It stays as a regression test.
  timestamp: 2026-09-22T14:22:31.508558+00:00
- actor: claude-code
  id: 01m34r4hpkh2dpp0cbzg4as937
  text: |-
    Implementation landed. `SnapshotRun.copyPartials(ofSourceRoots:skills:)` replaces the two old methods, `copyPartials(ofSourceRoots:)` and `copyPartials(ofSkills:besides:)`. Its only caller is `SnapshotWriter.write`. The new helpers are `partialsFolders(ofSourceRoots:skills:)`, `specificityLevels(of:)`, `sourceRoot(of:among:)`, `folders(from:downTo:)`, `depth(of:)` and the `treeRoot` constant. `parentFolders(ofSkills:)` is removed. The folder list starts with each source root in catalog order, then gives the walk of each skill that the root owns (the longest source root above the skill path). A skill with no owner root walks from the tree root. The list has no repeat. The copy goes one level (component count) at a time, and it forgets the partials writes after each level. Thus a more specific copy gives no diagnostic, and two folders at the same level give one.

    Walk tests: the include walk code exists already, so the four new walk tests passed the first time. They cover present behavior, as the card asks. Notes: `render(_:at:in:)` on the defaults layer also sees the partials of the project layer. The deep cross-layer test uses this.

    Docs: the SnapshotWriter type doc, the ResolvedCatalog.sourceRoots doc, the README Marketplace section and plan.md §12 "The partials of a snapshot" now state the nested-folder rule and the new known limit. There is no CHANGELOG entry.
  timestamp: 2026-09-22T14:25:53.363699+00:00
- actor: claude-code
  id: 01m34r4kw1qvkfpa4qw23h4759
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/Marketplace/SnapshotWriter.swift, Sources/Marketplace/CatalogResolver.swift (doc only), Tests/MarketplaceTests/SnapshotWriterTests.swift (4 new tests), Tests/FoundationModelsExtrasTests/PartialWalkTests.swift (4 new tests, 10 cases), README.md, plan.md. `swift build --build-tests`: Build complete, no warnings. `swift test`: 447 tests in 34 suites passed, 0 failures.
    - next: /review
  timestamp: 2026-09-22T14:25:55.585879+00:00
- actor: claude-code
  id: 01m34racd5vd8kzjehh4rwwra6
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (clean, via `swift package clean` first) — exit 0, 0 warnings. `swift test` — exit 0, all bundles passed.
    - per-bundle counts (Swift Testing): OperationsTests 125 tests/11 suites; OperationsMacrosTests 34 tests/3 suites; OperationsCLITests 44 tests/10 suites; NotesToolTests 26 tests/5 suites; MarketplaceTests 393 tests/28 suites; FoundationModelsExtrasTests 447 tests/34 suites. Total 1069 tests, 0 failures, 0 warnings.
    - XCTest legacy harness: 6 bundles report "Executed 0 tests, with 0 failures" — no XCTestCase tests exist in the repo.
    - 1 conditional guard found: `@Test(.disabled(if: isRoot, ...))` in Tests/FoundationModelsExtrasTests/DotfolderWatcherTests.swift. It did not trigger in this run — the test ran and passed.
    - no formatter config file in the repo (`.swift-format`, `.swiftformat`, `.swiftlint.yml` all absent; no Airbnb plugin dependency), so no format step applies.
    - next: none. Build and tests are clean.
  timestamp: 2026-09-22T14:29:04.549603+00:00
position_column: doing
position_ordinal: '80'
title: Copy the partials of every folder from the plugin root down to each skill, and test deep partial nesting
---
## Why

`^pdrpysg` requires that the snapshot copy the `_partials/` of each folder between the plugin source and each selected skill, from the least specific to the most specific. The code does not do this:

- `SnapshotRun.parentFolders(ofSkills:)` (`Sources/Marketplace/SnapshotWriter.swift:545`) gives only the folder that directly holds each skill. For a skill at `skills/group/review/`, the snapshot copies `skills/group/_partials/`, but not `skills/_partials/`.
- `copyPartials(ofSkills:besides:)` copies the folders in catalog order, not in order of specificity. Thus `skills/_partials/` can replace `skills/group/_partials/`, and the replacement gives the "two plugins" diagnostic, which is wrong for one plugin.

The tests of the include walk (`Tests/FoundationModelsExtrasTests/PartialWalkTests.swift`) cover three levels, each of which holds the partial. They do not cover a level with no copy, different partials from different levels, or more than three levels.

## What

### 1. The snapshot copy

1. For each selected skill, take every folder from the plugin source (or the root of a tree with no catalog) down to the folder that holds the skill. Example: for `skills/group/review/`, the folders are the source root, `skills/`, and `skills/group/`.
2. Copy the `_partials/` of each of these folders to `<snapshot>/_partials/`, from the least specific (fewest path components) to the most specific. Copy each folder one time only.
3. A copy from a more specific folder replaces a copy from a less specific folder, with no diagnostic.
4. Two different folders at the same level of specificity that give a partial with the same name (for example `skills/group-a/_partials/x.md` and `skills/group-b/_partials/x.md`, or two plugins): the later one in catalog order wins, with one diagnostic.
5. A `_partials/` inside a skill folder stays with the skill folder, as today.
6. Update the known-limit text in the documentation: in a flat snapshot, every skill and agent sees the merged partials of all these folders.

### 2. Tests of the include walk

Add tests to `PartialWalkTests.swift`:

1. **A level with no copy.** A document at `a/b/c/doc.md`, with no `a/b/c/_partials/` folder and an empty `a/b/_partials/` folder, gets the copy of `a/_partials/`.
2. **Different partials from different levels.** One document at `a/b/doc.md` includes `x` (only in `a/b/_partials/`), `y` (only in `a/_partials/`), and `z` (only in `_partials/` at the root). Each include gets its copy.
3. **Deep nesting.** A walk through five or more levels, with copies at some levels only, gets the nearest copy.
4. **Deep nesting across layers.** A more specific folder in a lower layer wins over a less specific folder in a higher layer, at five or more levels.

## Acceptance Criteria

- [x] A snapshot of a skill at `skills/group/review/` holds the partials of the source root, of `skills/`, and of `skills/group/` in `<snapshot>/_partials/`.
- [x] The most specific copy wins in the snapshot, whatever the catalog order, with no diagnostic.
- [x] Two folders at the same level of specificity with the same partial name: the later one in catalog order wins, with one diagnostic.
- [x] Each folder is copied one time only.
- [x] Every partial that resolves today resolves to the same file, except where a more specific folder now holds a copy.
- [x] The include walk skips a level with no copy and continues up.
- [x] One document gets different partials from different levels.
- [x] The walk works through five or more levels, in one layer and across layers.
- [x] README and `plan.md` describe the snapshot rule for nested folders. No CHANGELOG entry.
- [x] The Extras tests stay green.

## Tests

- [x] A snapshot test: a skill at `skills/group/review/` with `_partials/`, `skills/_partials/`, and `skills/group/_partials/`, each with its own partial and one shared name. The snapshot holds all three unique partials, and the shared name comes from `skills/group/_partials/`, with no diagnostic.
- [x] A snapshot test with a catalog order that lists the less specific folder last. The most specific copy still wins.
- [x] A snapshot test with `skills/group-a/_partials/x.md` and `skills/group-b/_partials/x.md`: the later one in catalog order wins, with one diagnostic.
- [x] A walk test for a level with no copy.
- [x] A walk test for different partials from different levels in one document.
- [x] A walk test through five or more levels.
- [x] A walk test through five or more levels across layers.

#marketplace #extras #partials