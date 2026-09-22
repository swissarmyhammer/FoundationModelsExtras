---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34nwc923hz43m909z9nrsye
  text: |-
    Research:
    - DotfolderLoader resolves each include through `layerStack.content(path)`. That call applies `isSafeRelativePath` and `PathConfinement` to each candidate path, thus the confinement checks apply at each level of the walk with no new code.
    - TemplateEngine makes the loader in `makeLoader()`. The internal init is the seam that StenciledDotfolderStack uses. The walk start goes through that seam as a new internal parameter.
    - StenciledDotfolderStack file lookups (`item`, `items`, `tree`, `content`) route through `rendered(_:)`, which knows the URL and the layer, thus the path of the document relative to the layer root.
    - SnapshotRun.copyPartials(ofSkills:) copies `<parent of skill>/_partials`. ResolvedCatalog does not carry the plugin source roots yet.
    - Other files that hold `skills/_partials/`: the fixture `swissarmyhammer-skills` (used by SnapshotWriterTests happy path), `SnapshotWriterTests.twoPartialFolderTree`, the layout-name test tree, `LayerPrecedenceExampleTests` (team-skills/skills/_partials) and its README copy. These must move to `_partials/` at the root, or they lose the partials after the change.
  timestamp: 2026-09-22T13:46:28.514405+00:00
- actor: claude-code
  id: 01m34p05hdg63w44vszb6cgcct
  text: |-
    The requirements changed before the first edit (section "User decisions"). No work needed an undo. Plan now:
    - Walk order: folder level outer (most specific first), layer inner (highest first). The diagnostic lists the folders in the same order.
    - File lookups of StenciledDotfolderStack (`content`, `item`, `items`, `tree`) walk from the path of the file relative to its layer root. `render(_:at:in:)` is the new public form for text that a consumer holds. `render(_:in:)` searches the layer root only.
    - Snapshot: two tiers into `<snapshot>/_partials/`. Tier 1: `<plugin source>/_partials/` of each plugin that gives the snapshot a skill or an agent (`<root>/_partials/` for no catalog). Tier 2: the parent folder of each selected skill, as today, less a folder that tier 1 already copied. A tier-2 copy replaces a tier-1 copy with no diagnostic. Two copies in one tier give the diagnostic, as today.
    - The swissarmyhammer-agents fixture stays as it is. New cases use in-memory trees with `_partials/` at the root. No CHANGELOG entry.
  timestamp: 2026-09-22T13:48:32.685545+00:00
- actor: claude-code
  id: 01m34pf8zw69861d2h2amnhatk
  text: |-
    Implementation landed (TDD: each new test failed first, then passed).
    - Walk: `DotfolderLoader` takes an optional `documentPath` and computes the folders of the walk once in `init` (most specific first, the layer root last). The search is folder outer, layer inner (highest first). The diagnostic lists `<layer root>/<folder>/<location>` in the same order. A document path that is absolute or holds `..` gives the layer root only. Each candidate path goes through `DotfolderStack.content`, thus through `isSafeRelativePath` and `PathConfinement`.
    - `TemplateEngine` internal init gets `documentPath:` (default `nil`) and passes it to the loader.
    - `StenciledDotfolderStack`: new public `render(_:at:in:)` for `QuarantinedText` and for `String`. `render(_:in:)` forwards with no path (layer root only). The file lookups (`content`, `item`, `items`, `tree`) compute the path of the file relative to its layer root and walk from there.
    - Snapshot: `ResolvedCatalog.sourceRoots` (plugin source of each selected plugin that gives a skill or an agent; `[""]` for a scan that gives something). The writer copies the root tier first, forgets those writes, then copies the parent folder of each skill (skipping a folder already copied as a root). A tier-2 copy replaces a tier-1 copy with no diagnostic; same-tier duplicates keep the diagnostic.
    - Discovery: a tier-2 file over a tier-1 symbolic link wrote THROUGH the link into its target, and a tier-2 link over a tier-1 file threw. New helper `removeEarlierItem(at:)` removes the earlier item first. Tests `aMoreSpecificFileReplacesALessSpecificLinkAndNotItsTarget` and `aMoreSpecificLinkReplacesALessSpecificFile` cover it.
    - Fixture `swissarmyhammer-agents` unchanged (skills/_partials still works); root `_partials/` cases are in-memory trees in SnapshotWriterTests. No CHANGELOG entry. README and plan.md document the walk, the order, the snapshot merge and the known limit.
    - Result: `swift build --build-tests` 0 warnings; `swift test` 1061 tests pass (125+34+44+26+389+443).
  timestamp: 2026-09-22T13:56:47.740015+00:00
- actor: claude-code
  id: 01m34pfb9qkeas960n6asnyz6v
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsExtras/DotfolderLoader.swift, Sources/FoundationModelsExtras/TemplateEngine.swift, Sources/FoundationModelsExtras/StenciledDotfolderStack.swift, Sources/Marketplace/CatalogResolver.swift, Sources/Marketplace/SnapshotWriter.swift, Tests/FoundationModelsExtrasTests/PartialWalkTests.swift (new), Tests/MarketplaceTests/SnapshotWriterTests.swift, README.md, plan.md; `swift build --build-tests` 0 warnings, `swift test` 1061 tests passed, 0 failed
    - next: /review
  timestamp: 2026-09-22T13:56:50.103980+00:00
- actor: claude-code
  id: 01m34pq12n846a348kasmm5x9v
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (clean rebuild after `swift package clean`) — 0 warnings, 0 errors. `swift test` — 1061 tests total across all targets, 0 failed, 0 skipped: FoundationModelsExtrasTests 443/443, MarketplaceTests 389/389 (including the "Marketplace snapshot writer" suite for the partials-copy work), OperationsTests 125/125, OperationsMacrosTests 34/34, OperationsCLITests 44/44, NotesToolTests 26/26.
    - next: ready for review.
  timestamp: 2026-09-22T14:01:01.781485+00:00
position_column: doing
position_ordinal: '80'
title: Resolve partials from the document up to the layer root, and copy the partials of the plugin root into a snapshot
---
## Where the request came from

The FoundationModelsAgents session asked for this card. It goes together with `^s8kdzy3` (the flat `agents/` folder).

## User decisions (these override every other text on this card)

1. **The most specific folder wins.** Partials override from the most specific folder to the least specific folder. Folder specificity comes first. Layer precedence applies only between copies in the same folder.
2. **`skills/_partials/` must continue to work**, in addition to `_partials/` at the root. Both are valid places.
3. **No CHANGELOG entry.** The change is fully backward compatible: every partial that resolves today resolves to the same file after the change.

## Why

In `swissarmyhammer/builtin`, `_partials/`, `agents/`, and `skills/` are siblings below one root, and a skill includes `_partials/step-record` against that root. The `../skills` marketplace has its partials in `skills/_partials/`. The snapshot writer copies the `_partials/` of each folder that holds a selected skill (`SnapshotRun.copyPartials(ofSkills:)` in `Sources/Marketplace/SnapshotWriter.swift`). Agents at `<plugin root>/agents/` cannot get those partials, and the `_partials/` of the plugin root is not copied.

Today the include search does not know where the document is:

- `DotfolderLoader.partialPaths(for:)` (`Sources/FoundationModelsExtras/DotfolderLoader.swift`) looks only in each `partialLocations` entry at the layer root.
- `StenciledDotfolderStack.render(_:in:)` takes the text and the layer, but not the path of the document.

## What

### 1. The include walk

1. An `{% include "_partials/x" %}` in a document at `<layer root>/a/b/doc.md` searches the folders in this order, the most specific first: `a/b/_partials/`, then `a/_partials/`, then `_partials/` at the layer root.
2. At each folder level, check every layer, the highest layer first. The first copy found wins. Thus a partial in a more specific folder wins over a partial in a less specific folder, also when the less specific copy is in a higher layer.
3. `DotfolderLoader` walks the ancestor folders of the document, from the folder of the document to the layer root. At each level, it checks each `partialLocations` entry.
4. `StenciledDotfolderStack` gets a render form that knows where the document is. Examples: `render(_:at:in:)`, which takes the path of the document relative to the layer root, or a form over the `Located` value that `FrontmatterDocumentStack` gives. Choose the shape during the work, and document it.
5. The current `render(_:in:)` stays, and it searches the layer root only, as today.
6. The diagnostic for a partial that no layer holds lists each folder that the walk searched, in search order.
7. The walk never goes above the layer root. The confinement checks of `DotfolderStack` apply at each level.

### 2. The snapshot copy

The snapshot is flat: a skill is at `<snapshot>/<skill>/`, and the folders between the plugin source and the skill (for example `skills/`) do not exist in the snapshot. Thus the partials of those folders go into `<snapshot>/_partials/`, merged from the least specific to the most specific:

1. First, copy `<plugin source>/_partials/` (for a tree with no catalog, `<root>/_partials/`) to `<snapshot>/_partials/`.
2. Then, copy the `_partials/` of each folder between the plugin source and each selected skill (for example `skills/_partials/`) to `<snapshot>/_partials/`, as today. A more specific copy replaces a less specific copy. This replacement is the intended rule, and it gives no diagnostic.
3. A `_partials/` folder inside a skill folder is copied with the skill folder, as today. The include walk finds it at `<snapshot>/<skill>/_partials/`, and it wins for that skill.
4. When two plugins give a partial of the same name at the same level of specificity, the later plugin wins, with one diagnostic, as for skills and agents.
5. Known limit of the flat snapshot: in a snapshot, an agent also sees the partials of `skills/_partials/`, because they merge into `<snapshot>/_partials/`. Record this limit in the documentation.

## Effects on other work

- The fixture `Tests/MarketplaceTests/Fixtures/catalogs/swissarmyhammer-agents/` holds its partials in `skills/_partials/`. Keep that fixture as it is: it proves that `skills/_partials/` still works. Add a second fixture, or a case, with `_partials/` at the root.
- No CHANGELOG entry (user decision 3).

## Acceptance Criteria

- [x] A skill at `<root>/commit/SKILL.md` and an agent at `<root>/agents/committer.md` both resolve `_partials/sah-x` to `<root>/_partials/sah-x.md`.
- [x] A partial at `<root>/skills/_partials/sah-x.md` wins over `<root>/_partials/sah-x.md` for a skill below `skills/`. An agent at `<root>/agents/` gets `<root>/_partials/sah-x.md`.
- [x] A partial at `<root>/commit/_partials/sah-x.md` wins for that skill only.
- [x] The most specific folder wins across layers: a partial in a more specific folder of a lower layer wins over a partial in a less specific folder of a higher layer.
- [x] In the same folder, the highest layer wins.
- [x] `render(_:in:)` keeps its current behavior.
- [x] The diagnostic for a partial that is not found lists each folder that the walk searched, in search order.
- [x] A snapshot of a plugin with `_partials/` at its source root holds those partials in `<snapshot>/_partials/`.
- [x] A snapshot of a plugin with `skills/_partials/` holds those partials in `<snapshot>/_partials/`, as today.
- [x] A snapshot of a plugin with both: `skills/_partials/` replaces the same name from `_partials/`, with no diagnostic.
- [x] A snapshot of a tree with no catalog holds the `_partials/` of the root.
- [x] Two plugins with a partial of the same name at the same level: the later plugin wins, with one diagnostic.
- [x] Every partial that resolves today resolves to the same file after the change.
- [x] The new public API has documentation. The README and `plan.md` describe the walk, the order, and the snapshot rule.
- [x] The Extras tests stay green.

## Tests

- [x] A test proves that a skill and an agent below one root both resolve a partial at the root.
- [x] A test proves that `skills/_partials/` wins over the root `_partials/` for a skill below `skills/`, and that an agent gets the root copy.
- [x] A test proves that a partial next to a skill wins for that skill only.
- [x] A test proves the order of the walk: the most specific folder first, the layer root last.
- [x] A test proves that a more specific folder in a lower layer wins over a less specific folder in a higher layer.
- [x] A test proves that in the same folder the highest layer wins.
- [x] A test proves that the walk does not go above the layer root.
- [x] A test proves the text of the diagnostic for a partial that is not found.
- [x] A test proves that a snapshot copies `<plugin source>/_partials/` and `skills/_partials/` into `<snapshot>/_partials/`, with the more specific copy winning and no diagnostic.
- [x] A test proves that a tree with no catalog copies `<root>/_partials/`.
- [x] A test proves that the later plugin wins for a partial with the same name at the same level, with one diagnostic.
- [x] The existing `swissarmyhammer-agents` fixture test (partials in `skills/_partials/`) stays green.

#marketplace #extras #cross-repo #partials