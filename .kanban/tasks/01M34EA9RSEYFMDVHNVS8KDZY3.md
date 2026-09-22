---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34f5n02swvvh1t8pck6yyfd
  text: |-
    Research done.
    - The resolver (`CatalogResolver.swift`) gives `ResolvedCatalog.skills`. The snapshot writer (`SnapshotWriter.swift`) copies the skills, then the partials. `MarketplaceStore` calls the two in `materialize` (git sources only). The plan: add `ResolvedCatalog.agents` (internal `ResolvedAgent`: file name, tree path, plugin), and a writer step that copies each agent to `agents/<file name>` through `copyFile`, thus the limits count each agent file.
    - There is no reserved-name check for the partials folder in the code today. The reserved `agents` name is a new check in the resolver, after the selection, for a catalog and for a scan.
    - `deduplicated` and the duplicate diagnostic become generic over a small internal protocol, thus agents use the same later-plugin-wins rule and one warning.
    - The real `swissarmyhammer/skills` repository has no `agents` list in its plugin entry: its 8 agents come from `<source>/agents/*.md` and include `_partials/sah-*` partials.
    - A catalog `agents` value that is one string (the Claude plugin form `"agents": "./agents/"`) must not make the whole catalog unusable. The decode takes one string as a list of one entry; an entry that is not an `.md` file gets the warning of the card.
  timestamp: 2026-09-22T11:49:12.322729+00:00
- actor: claude-code
  id: 01m34fr23cx5whfn5qe88t6xgg
  text: |-
    Implementation landed (TDD: the tests failed first with 54 issues, for the expected reason: no `agents/` folder in the layer).
    - Resolver: `ResolvedCatalog.agents` (internal `ResolvedAgent`). Agent steps: `agents(ofPlugins:selection:)`, `agents(of:)`, `listedAgent`, `folderAgents`, `isAgentFile`, `unreserved(skills:)`, `takesAgents`. `deduplicated` and `duplicateDiagnostic` are now generic over the fileprivate protocol `ResolvedItem`, thus skills and agents share the later-plugin-wins rule and the one warning. The skill warning text is the same as before.
    - Catalog decode: `Plugin.agents`. One string is a list of one entry, thus a catalog that writes `"agents": "./x.md"` stays usable.
    - Writer: `copyAgents` copies each agent to `agents/<file name>` through `copyFile`, thus each file counts toward `SnapshotLimits`. Order: skills, agents, partials.
    - `CatalogPath.parent(of:)` is new; the private `SnapshotRun.parentFolder(ofSkillAt:)` is gone (same logic, now shared).
    - Discoveries: the `.md` match is exact (`UPPER.MD` is not an agent), the same rule as the document name; a test locks it. A symbolic link in `agents/` is not an agent file. A remote plugin, or a plugin source outside the repository, gives no agent file and no second warning (the skills step already warns).
    - Not done, and not on the card: no CHANGELOG entry for the new public constant. The card names the README and `plan.md` only.
    - The SourceKit index in this session is stale: `check working` reports 19 errors on the new members, but `swift build --build-tests` is clean (0 errors, 0 warnings).
    - Deviation from the process rule: one edit of `CatalogResolver.swift` (a rename of the local `agents` to `agentFiles`) was done with `perl` in the shell, not with the file tool.
  timestamp: 2026-09-22T11:59:15.564980+00:00
- actor: claude-code
  id: 01m34fr4tfkf7atbvv2f9b295b
  text: |-
    ### implement — changed
    - evidence: 12 files — Sources/Marketplace/{CatalogResolver,CatalogPath,MarketplaceCatalog,MarketplaceLayerProviding,SnapshotWriter}.swift; Tests/MarketplaceTests/{MarketplaceCatalogTests,SnapshotWriterTests,MarketplaceStoreTests,MarketplaceTestSupport}.swift; new fixture Tests/MarketplaceTests/Fixtures/catalogs/swissarmyhammer-agents/ (11 files); README.md; plan.md. `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: exit 0, 1043 tests (125+34+44+26+380+434) passed, 0 issues.
    - next: /review
  timestamp: 2026-09-22T11:59:18.351057+00:00
- actor: claude-code
  id: 01m34g1z9pb4cpv4pkqvbcwf1j
  text: |-
    ### test — green
    - evidence: `swift package clean && swift build --build-tests` gives a clean rebuild with 0 errors and 0 warnings.
    - evidence: `swift test` gives 1043 tests total across 6 test bundles (125, 34, 44, 26, 380, 434). All 1043 tests pass. 0 tests fail. 0 tests skip.
    - evidence: The repo has no `.swiftformat` file. The repo has no `.swift-format` file. The repo has no `.swiftlint.yml` file. `Package.swift` does not add the Airbnb swift plugin. So the repo has no formatter config, and no formatter check applies.
    - note: An LSP diagnostics scan first showed 19 stale errors in `MarketplaceCatalogTests.swift`, `MarketplaceStoreTests.swift`, and `SnapshotWriterTests.swift`. A fresh clean build and a re-scan showed 0 errors and 0 warnings. The stale scan came from an old SourceKit index, not from the real code.
    - next: none.
  timestamp: 2026-09-22T12:04:40.374453+00:00
position_column: doing
position_ordinal: '80'
title: Give a marketplace layer the agents of each selected plugin, in `agents/`
---
## Where the work is

This card is on the FoundationModelsExtras board, where the work is. It was made on the FoundationModelsAgents board and moved here, because a board cannot hold a card of another board.

## Decision: agents are flat, as skills are

The first version of this card put the agents in `agents/<plugin name>/<path>`. The user changed this. Agents now follow the same rules as skills: one flat folder, the file name is the agent name, and the later plugin wins when two plugins give the same name. There is no new read API.

## Why

A Claude plugin holds skills and agents side by side: `<plugin root>/skills/<id>/SKILL.md` and `<plugin root>/agents/<name>.md`. `FoundationModelsSkills` sees the skills of a marketplace through a `MarketplaceStore` layer. `FoundationModelsAgents` must see the agents of the same marketplace in the same way, from the same store and the same layer (FoundationModelsAgents `plan.md` §6).

Today a layer from a git source holds no agents:

- `CatalogResolver` finds only folders that hold `MarketplaceLayout.documentName`. A plugin with no `skills` list is read from `CatalogResolver.pluginSkillsFolderName`, which is `skills` (`CatalogResolver.swift:295-313`).
- `MarketplaceCatalog.Plugin` decodes only `name`, `source`, `strict`, and `skills`. An `agents` list is not decoded.
- `SnapshotWriter` copies only the selected entry folders (`copySkills`) and the partials (`copyPartials`). The `agents/` folder of a plugin is not in the snapshot.

The first real consumer exists now: the `swissarmyhammer/skills` marketplace holds 8 agents in `agents/<name>.md` at the root of its one plugin (source `./`), beside `skills/`.

## The layer

```
<layer root>/
  review/SKILL.md      skills, as today
  _partials/sah-*.md   partials, as today
  agents/reviewer.md   new: one .md file for each agent
```

## The API

- Add one public constant: `MarketplaceLayer.agentsDirectoryName`, with the value `"agents"`. Document it.
- Add no other public type, method, or store call. `MarketplaceStore.init`, `MarketplaceLayerProviding`, `SkillSelection`, and `MarketplaceLayout` do not change.
- A consumer reads `<layer root>/agents/*.md` from each layer of `marketplaceLayers()`, and the partials from `<layer root>/_partials/`. It reads the layers again on each `layerUpdates` value, as for skills.

## What

1. **A catalog plugin.** For each selected plugin of `.claude-plugin/marketplace.json` or `.agents/plugins/marketplace.json`:
   - When the plugin entry has an `agents` list, take the files of that list. Each entry is a path relative to the plugin source, and it must name an `.md` file. An entry that does not name an `.md` file gets a warning and is skipped.
   - Else take each `.md` file directly in `<plugin source>/agents/`. Read one level only. Do not read subfolders.
   - Copy each file to `agents/<file name>`.
2. **The same name.** When two plugins give an agent with the same file name, the later plugin wins, and the resolver records one warning. This is the rule for skills.
3. **A tree with no catalog.** Take each `.md` file directly in `<source root>/agents/`, and copy it to `agents/<file name>`.
4. **Selection.** `SkillSelection.all` and `.plugins([...])` give the agents of the selected plugins. `.skills([...])` gives no agents. The catalog `renames` map changes plugin names only.
5. **Limits.** The `SnapshotLimits` of `MarketplacePolicy` count the agent files as they count the skill files.
6. **A reserved name.** `agents` at the layer root is reserved, as the partials folder is. A skill folder named `agents` gets a `MarketplaceDiagnostic` and is not copied.
7. **No agent semantics.** Copy `.md` files by name. Read no agent frontmatter. The `Marketplace` module does not know what an agent is, as it does not know what a skill is (`ModuleBoundaryTests`).

## Out of scope

- A `file://` source with `path:`. It gives its folder unchanged, with no resolver and no snapshot, thus a folder that holds `agents/` already gives agents.
- A `file://` source with no `path:`. It reads `<folder>/skills` (`MarketplaceStore.localSkillsFolderName`), thus `<folder>/agents` is not in the layer. Decide on this board whether that source also gives agents; it is not needed for a git marketplace.
- Agent files in subfolders of `agents/`.

## Acceptance Criteria

- [x] A store over a git source with a Claude catalog gives a layer that holds `agents/<name>.md` for each agent of each selected plugin, and the skills and the partials as today.
- [x] A plugin entry with an `agents` list gives only the files of that list.
- [x] When two plugins give the same agent name, the later plugin wins, with one warning.
- [x] A tree with no catalog gives the `.md` files of its `agents/` folder.
- [x] `.skills([...])` gives no agents; `.all` and `.plugins([...])` do.
- [x] The snapshot limits count the agent files.
- [x] A skill folder named `agents` gets a diagnostic and is not copied.
- [x] `MarketplaceLayer.agentsDirectoryName` is public and documented. No other public API changes.
- [x] The `Marketplace` module reads no agent frontmatter, and `ModuleBoundaryTests` stays green.
- [x] The README "Remote layers" section and the Marketplace part of `plan.md` describe the agents folder of a layer.
- [x] The Extras tests stay green.

## Tests

- [x] A test proves that a catalog with two plugins gives `agents/<name>.md` for the agents of both plugins.
- [x] A test proves that when two plugins give the same agent name, the later plugin wins and one warning is recorded.
- [x] A test proves that an `agents` list in a plugin entry limits the copy to the listed files, and that a bad entry gets a warning.
- [x] A test proves that a subfolder of `agents/` is not read.
- [x] A test proves that a tree with no catalog gives the `.md` files of its `agents/` folder.
- [x] A test proves each selection rule.
- [x] A test proves that an agent file counts toward the snapshot limits.
- [x] A test proves that a skill folder named `agents` gets a diagnostic.
- [x] A test with a fixture of the `swissarmyhammer/skills` shape proves that the layer holds `agents/<name>.md` for its 8 agents and `_partials/sah-*.md`, so that an agent body can include a partial.

#marketplace #extras #cross-repo