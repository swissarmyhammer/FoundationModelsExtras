---
depends_on:
- 01M2XDH57XW45Z6W0V3JHJ8KD2
position_column: todo
position_ordinal: '8280'
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