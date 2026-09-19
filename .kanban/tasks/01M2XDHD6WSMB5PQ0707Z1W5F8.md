---
comments:
- actor: claude-code
  id: 01m2xjwhv5r8ex3qw1g8yccda1
  text: |-
    Picked up. Research findings:

    - The Skills sources to move are `Marketplace/MarketplaceCatalog.swift`, `Marketplace/CatalogFileSource.swift` (only `LocalCatalogFileSource` is not here yet) and `Marketplace/CatalogResolver.swift`, all with 4-space indentation. The Skills tests are `MarketplaceCatalogTests.swift` and `GitTreeFileSourceTests.swift`. They call `ReloadTestSupport.skillFileContents(id:)`, `FixtureLibrary.marketplaceCatalog(named:)` and `MarketplaceTestSupport.makeTempDirectory(withFiles:)`, none of which is in this package.
    - `CatalogResolver` in Skills names `SkillDiscovery.skillFileName`, `SkillDiscovery.excludedDirectoryNames` and `FrontmatterDecoder.decode(text:)`. It also names `SkillDiscovery` in the doc comment of `folderSkills` ("Discovery skips such a folder in the same way") and of `isSubfolder`.
    - The Skills `LocalCatalogFileSource` calls `PathConfinement.resolvedURL(relativePath:in:)`. This package has `PathConfinement.isConfined(_:to:)` in the core target, but it is `internal`, thus the `Marketplace` target cannot call it. The text check of a relative path is already `CatalogPath.normalized(path:)` here.
    - The core target has `FrontmatterDocument.split(text:)` (public, `(frontmatter: String?, body: String)`) and `YAMLValue.parse(_:)` (public, throws `YAMLValueParsingError`, gives `.dictionary([String: YAMLValue])` for a map and `.string` for a text scalar).
    - The 11 fixture catalogs hold 53 files and no symbolic link. `cp -R` copied them into `Tests/MarketplaceTests/Fixtures/catalogs/`; `diff -r` shows the copy is identical.
    - `FoundationModelsExtrasTests` declares `resources: [.copy("Fixtures")]` and reads the files off the disk through `FixtureFile`. `FixtureFile.url(_:)` resolves a path relative to the package root.
    - `_partials` is the convention of the core `DotfolderLoader` (`defaultPartialLocations`, internal) and `StenciledDotfolderStack.defaultPartialLocations` (public, an array).
    - No file in `Sources/Marketplace` holds the literal `SKILL.md` today. `CatalogFileSource.swift` and `CatalogPath.swift` carry doc comments that say card ^7z1w5f8 brings the rest, and `CatalogTreeEntry.kind` carries a `// periphery:ignore` marker with the reason that the resolver of this card reads it.
    - The `GitTransportTests` of card ^jhj8kd2 already prove a tree read over a fetched commit. The moved `GitTreeFileSourceTests` prove the tree source over a fixture commit with no fetch, plus the parity suite. Both stay.
  timestamp: 2026-09-19T19:39:27.461331+00:00
- actor: claude-code
  id: 01m2xjx6tpxwv9jxrt8hvsbpff
  text: |-
    Decisions:

    1. `CatalogPath` stays in `Sources/Marketplace/CatalogPath.swift`, where card ^jhj8kd2 put it. This card adds the four members that the resolver calls (`resolved(relativePath:inFolder:)`, `lastComponent(of:)`, `isSingleComponent(name:)`, `display(path:)`) to that file, and removes the doc comment that names this card. The card description lists `CatalogPath` under `CatalogResolver.swift`, but a second copy or a move of an existing file would be a change with no reason.
    2. `MarketplaceLayout` is a public struct with a public memberwise initializer. `documentName` has no default. `excludedDirectoryNames` has the default `[".git", "node_modules"]` and `partialsDirectoryName` has the default `"_partials"`, because the card says that only `documentName` has no default, and both values are conventions of git, of npm and of the core `DotfolderLoader`, not skill knowledge.
    3. `CatalogResolver.resolve(from:selection:layout:)` takes the layout as a third parameter. The private `CatalogReader` holds it, and `isSkillFile` and `isSubfolder` become instance methods `isDocument(entry:)` and `isSubfolder(entry:)` that read it. The type names `ResolvedSkill`, `SkillSelection` and the `skills` vocabulary stay, as the card orders.
    4. The diagnostic texts interpolate `layout.documentName` with no backticks: `which has no SKILL.md file. The resolver skips it.` and `The root SKILL.md has no frontmatter name that is one folder name. The resolver skips it.` for a `SKILL.md` layout. That is the same text as in Skills, thus the store diagnostics do not change. The backticks in the card text read as markdown for the placeholder.
    5. The root document name read: `FrontmatterDocument.split(text:)`, then `YAMLValue.parse` of the frontmatter, then the `name` key as a `.string`. A `nil` frontmatter, a parse error, a value that is not a map, a missing key, a value that is not a string, and a name that is not one folder name all give no name, thus one warning. The Skills quoting fallback for `description:` is not moved; the card orders the plain split and parse.
    6. The `// periphery:ignore` marker on `CatalogTreeEntry.kind` and its reason line are removed, because `isDocument(entry:)` and `isSubfolder(entry:)` read `kind` in production now.
    7. `LocalCatalogFileSource` needs the symbolic-link confinement rule. The core `PathConfinement.isConfined(_:to:)` is `internal` to the core module. This card makes the core `PathConfinement` enum and `isConfined(_:to:)` public, with the doc comment saying that the marketplace local file source applies the same rule. A private copy of the twenty-line resolution in `Marketplace` would be a duplicate of core code. The text check stays `CatalogPath.normalized(path:)`, which already exists here.
    8. Test support: `MarketplaceTestSupport` gets `skillsLayout` (`MarketplaceLayout(documentName: "SKILL.md")`), `catalogFixture(named:)` over `FixtureFile.url`, and `makeTempDirectory(withFiles:)` over `TemporaryDirectory.make()` with no default, because two suites share them. A test that needs an empty folder calls `TemporaryDirectory.make()` directly (card ^vms0qv0 decision 6). The Skills `skillFileContents(id:)` becomes the private `skillDocument(named:)` of `MarketplaceCatalogTests`: a `SKILL.md` text with a plain `name` and `description` frontmatter.
    9. New tests beyond the moved ones: `MarketplaceLayoutTests` proves the values and the defaults of the layout (`partialsDirectoryName` has no production reader until the snapshot card, the same reason as `MarketplaceTimeoutErrorTests`). `MarketplaceCatalogTests` gains: the two diagnostic texts, a root document with unparseable frontmatter, a folder document with unparseable frontmatter, a layout with another document name, a layout with its own excluded names, and a lowercase `skill.md` that is not a document.
    10. `Package.swift` declares `.copy("Fixtures")` on `MarketplaceTests`, the way `FoundationModelsExtrasTests` does.

    TDD plan: RED: the test files, the test support, the fixtures and the manifest are in place; `swift build --build-tests` fails on `MarketplaceLayout`, `CatalogResolver`, `LocalCatalogFileSource`. GREEN: `MarketplaceLayout.swift`, `MarketplaceCatalog.swift`, `CatalogResolver.swift`, the `LocalCatalogFileSource` in `CatalogFileSource.swift`, the `CatalogPath` members, and the public `PathConfinement`.
  timestamp: 2026-09-19T19:39:48.950367+00:00
- actor: claude-code
  id: 01m2xkew2qz38bpt8s3zry2jng
  text: |-
    Implementation landed. Notes for the next agent:

    - TDD cycle: RED was `swift build --build-tests` with the three test files, the changed `MarketplaceTestSupport.swift`, the fixtures and the manifest in place, and no moved source; the compiler stopped with `cannot find 'MarketplaceLayout' in scope` (exit 1). GREEN was the six source changes; the same build completes with no `warning:` line, `swift test --filter MarketplaceTests` passes 194 tests in 14 suites, and the full `swift test` passes 6 bundles (125 + 34 + 44 + 26 + 194 + 367 = 790 tests), 0 failures.
    - The review rules were read in full through a subagent digest (the rules file is 12,096 lines). Two rules changed the code before the GREEN build: `swift/idioms` forbids the call form for an empty collection, thus the `[MarketplaceCatalog.Plugin]()` of the Skills `scanned(selection:)` became a typed `let noPlugins: [MarketplaceCatalog.Plugin] = []`; and `dead-code-swift` prescribes the `// periphery:ignore` marker with a reason line above it for a property that only a synthesized `Hashable` reads. `MarketplaceCatalog.Owner.email`, `RemotePluginSource.ref` and `RemotePluginSource.sha` have that shape (no explicit reader in production or in a test; the same shape as the `kind` finding of card ^jhj8kd2), thus each carries the marker now.
    - The diagnostic texts for a `SKILL.md` layout are byte for byte the Skills texts; two new tests pin them (`theWarningForAListedFolderNamesTheDocumentOfTheLayout`, `theWarningForARootDocumentWithNoNameNamesTheDocumentOfTheLayout`).
    - The core `PathConfinement` and its `isConfined(_:to:)` are public now (decision 7). No caller changed; the only new caller is `LocalCatalogFileSource.resolvedURL(forPath:)`.
    - `GitTreeFileSource.swift` did not change. Its doc comment names `LocalCatalogFileSource`, which exists now.
    - A grep over `Sources/Marketplace` for `SkillDiscovery`, `FrontmatterDecoder`, `SkillValidator` and `7z1w5f8` finds nothing. The literal `SKILL.md` is only in the doc comment of `MarketplaceLayout.documentName`.
    - The `FoundationModelsSkills` working tree shows changes to `Examples/skills-demo/WatchMode.swift`, `Sources/FoundationModelsSkills/Render/RenderPipeline.swift` and two new kanban files that were not there when this card started. None of them is from this card: this card read that repository only, and wrote nothing there.
    - The 53 fixture files under `Tests/MarketplaceTests/Fixtures/catalogs/` are an identical copy (`diff -r`) of the Skills fixtures.
  timestamp: 2026-09-19T19:49:27.767822+00:00
- actor: claude-code
  id: 01m2xkfandfdkrnsh3bzjd3n2v
  text: |-
    ### implement — changed
    - evidence: 13 files and 53 fixture files. Modified: Package.swift, Sources/FoundationModelsExtras/PathConfinement.swift, Sources/Marketplace/CatalogFileSource.swift, Sources/Marketplace/CatalogPath.swift, Tests/MarketplaceTests/MarketplaceTestSupport.swift. Added: Sources/Marketplace/CatalogResolver.swift, Sources/Marketplace/MarketplaceCatalog.swift, Sources/Marketplace/MarketplaceLayout.swift, Tests/MarketplaceTests/GitTreeFileSourceTests.swift, Tests/MarketplaceTests/MarketplaceCatalogTests.swift, Tests/MarketplaceTests/MarketplaceLayoutTests.swift, Tests/MarketplaceTests/Fixtures/catalogs/ (11 catalogs, 53 files). RED: `swift build --build-tests` failed with `cannot find 'MarketplaceLayout' in scope` (exit 1). GREEN: `swift build --build-tests` exit 0, 0 warnings; `swift test --filter MarketplaceTests` 194 tests in 14 suites pass; `swift test` 790 tests in 6 bundles pass, 0 failures. No change in `FoundationModelsSkills`.
    - next: `/review` moves the card into review.
  timestamp: 2026-09-19T19:49:42.701341+00:00
- actor: claude-code
  id: 01m2xkpbg8zrrtdd29kq1hep66
  text: |-
    ### test — green
    - evidence: swift package clean && swift build --build-tests (0 warnings, 0 errors, exit 0); swift test (6 test bundles: 125, 34, 44, 26, 194, 367 tests — 790 tests total, 30+ suites, 0 failed, 0 skipped, exit 0)
    - next: the build and the tests are clean. the review step can start.
  timestamp: 2026-09-19T19:53:32.936072+00:00
- actor: claude-code
  id: 01m2xkqm1qs876m5kdg1wfz7ph
  text: |-
    ### commit — changed
    - evidence: 6ab7281 feat(marketplace): move the catalog formats and the catalog resolver
    - next: the review step can start.
  timestamp: 2026-09-19T19:54:14.455273+00:00
- actor: claude-code
  id: 01m2xm07xw6qvmck7gfavc6akn
  text: |-
    ### review — clean
    - evidence: 0 findings. Scope `review sha HEAD~1..HEAD` (commit 6ab7281). The engine reviewed 11 files. Counts: findings 0, confirmed 0, refuted 0, attempted 14, failed 0. The task holds no prior review findings.
    - next: none. The task moved from `review` to `done`.
  timestamp: 2026-09-19T19:58:56.956888+00:00
- actor: claude-code
  id: 01m2xm0t83mjax9hay2mj3t489
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 13 files and 53 fixture files
    - test: green — swift test, 790 passed in 6 bundles, 0 failed, 0 skipped
    - commit: 6ab7281
    - review: clean — 0 findings, task moved to done
  timestamp: 2026-09-19T19:59:15.715071+00:00
depends_on:
- 01M2XDH57XW45Z6W0V3JHJ8KD2
position_column: done
position_ordinal: ac80
title: Move the catalog formats and the catalog resolver, with the document name as a MarketplaceLayout parameter
---
## What

In the `Marketplace` target, move the catalog read: the catalog formats, the file source protocol, and the resolver that turns a catalog plus a tree into the list of entries to materialize.

`CatalogResolver` in Skills holds three pieces of skill knowledge: `SkillDiscovery.skillFileName` (`SKILL.md`), `SkillDiscovery.excludedDirectoryNames` (`.git`, `node_modules`), and `FrontmatterDecoder.decode(text:)` to read the `name` of a root `SKILL.md`. This package does not know what a skill is, so these become inputs.

1. Move these files from `../FoundationModelsSkills/Sources/FoundationModelsSkills/Marketplace/` into `Sources/Marketplace/`, with 2-space indentation: `MarketplaceCatalog.swift` (`MarketplaceCatalog` with `Owner`, `Metadata`, `Plugin`, `PluginSource`, `RemotePluginSource`), `CatalogFileSource.swift` (`CatalogFileSource`, `CatalogTreeEntry`, `CatalogFileSourceError`, `LocalCatalogFileSource`), `CatalogResolver.swift` (`ResolvedCatalog`, `ResolvedSkill`, `CatalogResolver`, `CatalogPath`, `SelectionNoun`, `DuplicateWinner`).
2. Add a public value `MarketplaceLayout` in `Sources/Marketplace/MarketplaceLayout.swift` with `documentName: String` (the file that marks an entry folder, `SKILL.md` for skills), `excludedDirectoryNames: Set<String>`, and `partialsDirectoryName: String` (`_partials` for skills). It has no default for `documentName`; the host names its format. `CatalogResolver` takes a `MarketplaceLayout` in place of the `SkillDiscovery` constants. The later store card passes it through.
3. The root-document name read: replace `FrontmatterDecoder.decode(text:)` with `FrontmatterDocument.split` from the core target and `YAMLValue.parse` of the frontmatter, then the `name` string key. A frontmatter that does not parse gives no name, the same as a decode failure did.
4. The diagnostic texts and the doc comments of `CatalogResolver` name `SKILL.md` today (for example "which has no SKILL.md file. The resolver skips it." and "The root SKILL.md has no frontmatter name"). Each diagnostic interpolates `layout.documentName` in place of the literal, so the text becomes "which has no `<documentName>` file. The resolver skips it." and "The root `<documentName>` has no frontmatter name". Each doc comment says "the document that marks an entry folder". The moved `MarketplaceCatalogTests` assertions follow the new texts, with the layout of the test giving `SKILL.md`.
5. Keep the catalog vocabulary as it is: the Claude plugin catalog has a `skills` field and the repository convention is a `skills/` folder. That is the external format, not skill knowledge of this package.
6. Copy the 11 catalog fixtures of `../FoundationModelsSkills/Examples/marketplace-fixtures/catalogs/` into `Tests/MarketplaceTests/Fixtures/catalogs/`, declared as a `.copy` resource of the test target the way `FoundationModelsExtrasTests` declares its `Fixtures`. Read them through `FixtureSupport.FixtureFile`.
7. Move the tests `MarketplaceCatalogTests.swift` and `GitTreeFileSourceTests.swift` into `Tests/MarketplaceTests/`. Their skill-tree helper (`skillTree(body:)` in the Skills `MarketplaceTestSupport`) becomes a local helper that writes `<name>/SKILL.md` with a plain frontmatter; it does not import anything from Skills.
8. Do not delete anything in `FoundationModelsSkills`.

## Acceptance Criteria

- [ ] `CatalogResolver` resolves the Claude format, the Codex format and the repository scan over a `CatalogFileSource`, with the same selections, renames, duplicate rules and diagnostics as in Skills, for every fixture catalog.
- [ ] No file in `Sources/Marketplace` names `SkillDiscovery`, `FrontmatterDecoder` or `SkillValidator`; the literal `SKILL.md` appears in `Sources/Marketplace` only in the doc comment of `MarketplaceLayout.documentName` as the example value, and every diagnostic text interpolates the layout value.
- [ ] `GitTreeFileSource` reads the tree and the blobs of a commit and gives the same entries as `LocalCatalogFileSource` over the same fixture.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.

## Tests

- [ ] `Tests/MarketplaceTests/MarketplaceCatalogTests.swift`: each fixture catalog resolves to the expected entries; a plugin selection and a name selection filter; a rename is recorded; a duplicate follows `DuplicateWinner`; an unknown name gives a diagnostic and no error.
- [ ] Same file: a root document whose frontmatter names the entry gives that name, and a frontmatter that does not parse gives the folder name.
- [ ] `Tests/MarketplaceTests/GitTreeFileSourceTests.swift`: parity of the tree read against `LocalCatalogFileSource` for every fixture catalog committed into a `GitFixtureRepository`.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#marketplace #cross-repo