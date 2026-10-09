---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4gps1c5ppgqhpy8es1mmty2
  text: |-
    Research done. Findings:
    - The resolver is `Sources/Marketplace/CatalogResolver.swift` (types `ResolvedCatalog`, `ResolvedSkill`, `ResolvedAgent`, `CatalogReader`). The catalog model is `MarketplaceCatalog.swift`. Only the resolver, `SnapshotWriter` and `MarketplaceStore` use them.
    - `MarketplaceStore` takes the display id from the catalog `name` and `catalogVersion` from `metadata.version`. With no catalog, the display id is always the pre-fetch key and the version is always nil. The public fields `MarketplaceProvenance.catalogVersion`, `MarketplaceListing.catalogVersion` and the state fields stay in this task, because the card does not name them (public API). A follow-up task removes them.
    - `duplicateDisplayIDDiagnostics` in the store can fire only when two catalogs have the same `name`. The pre-fetch keys are unique (a duplicate key refuses the list), thus that check becomes dead code with the catalog read gone.
    - `Examples/agent-library` is not in this repo. It is in `../FoundationModelsAgents/Examples/agent-library`. This task does not change that repo.
    - The fixture trees are in `Tests/MarketplaceTests/Fixtures/catalogs/`. `GitTreeFileSourceTests` runs a parity test over a list of fixture names.
    - Partials: with no plugin source roots, each walk starts at the tree root and goes down to the folder that holds each selected entry (skill or agent).
  timestamp: 2026-10-09T16:08:42.629254+00:00
- actor: claude-code
  id: 01m4gr4tjky3ae28zf89zk7gce
  text: |-
    Implementation landed. Notes for the next agent:
    - `CatalogResolver.swift` is now a folder scan (`TreeScanner`, breadth first, no depth limit). Types: `ResolvedCatalog { skills, agents, diagnostics }` and `ResolvedEntry { name, path }`. `ResolvedSkill`, `ResolvedAgent`, `MarketplaceCatalog.swift` and `CatalogPath.resolved` are deleted.
    - New public constant `MarketplaceLayer.agentDocumentName = "AGENT.md"`.
    - A root document (SKILL.md or AGENT.md at the tree root) makes the whole tree one entry, named by its frontmatter `name`, and stops the scan. This keeps the old root-skill rule.
    - Duplicate warnings of skills come before the selection, thus `.skills([...])` still reports a duplicate of an unselected skill. The agent warnings (old agent files, duplicate agents) come only with `.all`.
    - `SkillSelection` decode uses a coding key that takes any text, so `{"plugins": [...], "skills": [...]}` does not decode (a stale `plugins` key is not dropped silently).
    - `SnapshotWriter` copies each agent folder as a tree (`copyTree`, same limits and link rules). The partials walk starts at the tree root for each selected skill and each agent. Folders at one level are sorted in path order (component by component), so the later folder in path order wins.
    - `SnapshotError.escapingSymlink` text now says "outside its entry folder", because agent folders use the same rule.
    - `MarketplaceStore`: the display id of an install is the pre-fetch key, and `catalogVersion` is nil. `duplicateDisplayIDDiagnostics` is deleted (dead: pre-fetch keys are unique). The public `catalogVersion` and `displayID` fields stay; follow-up task ^77e7ynm.
    - Fixtures moved from `Tests/MarketplaceTests/Fixtures/catalogs` to `.../marketplaces`. Catalog-only fixtures are deleted. New fixture `agent-library` has the `plugins/<name>/{skills,agents}/` layout. `MarketplaceCatalogTests.swift` is now `MarketplaceScanTests.swift`.
    - `Examples/agent-library` is in `../FoundationModelsAgents`, not in this repo. This task does not change it.
    - The build prints `warning: missing creator for mutated node: ... mlx-swift_Cmlx.bundle/Contents/MacOS`. It comes from the build system for the mlx bundle, not from the Marketplace sources.
    - `swift test`: all suites pass (Marketplace suite: 381 tests in 28 suites). The 11 known issues are in `TelemetryCaptureTests` (`withKnownIssue`), not in this change.
    - Not committed. The sessions foundationmodelsagents-3d and skills-79 are not told yet: tell them after the commit.
  timestamp: 2026-10-09T16:32:37.459363+00:00
- actor: claude-code
  id: 01m4gr4yt5rspvf6q003wctpaj
  text: |-
    ### implement — changed
    - evidence: Sources/Marketplace/{CatalogResolver,CatalogPath,SnapshotWriter,SkillSelection,MarketplaceStore,MarketplaceLayerProviding,MarketplaceLayout,MarketplaceListing,MarketplaceSource,MarketplaceIdentity,MarketplaceDiagnostic}.swift; deleted Sources/Marketplace/MarketplaceCatalog.swift; Tests/MarketplaceTests/{MarketplaceScanTests (was MarketplaceCatalogTests),SnapshotWriterTests,MarketplaceStoreTests,MarketplaceTestSupport,GitTreeFileSourceTests,MarketplaceSourceTests,MarketplaceConfigTests,ReadmeSnippetTests}.swift; fixtures moved to Tests/MarketplaceTests/Fixtures/marketplaces (catalog files removed, agents as folders, new agent-library); README.md, CHANGELOG.md, plan.md, Package.swift. `swift build --build-tests` clean of Swift warnings; `swift test`: all suites pass (Marketplace 381 tests / 28 suites; core 913 tests, 11 known issues pre-existing in TelemetryCaptureTests).
    - next: /review. Follow-up task ^77e7ynm for the public catalogVersion and displayID fields.
  timestamp: 2026-10-09T16:32:41.797250+00:00
- actor: claude-code
  id: 01m4grcre7j2ass548dsyqhvxe
  text: |-
    ### test — green
    - evidence: swift test — 913 tests in 87 suites passed, 0 failed, 0 skipped. 0 compiler warnings from the source. 11 known issues come from withKnownIssue in TelemetryCaptureTests.swift. The tests use it on purpose to prove that the capture records a forbidden string. One build tool warning ("missing creator for mutated node", mlx-swift_Cmlx.bundle) comes from a dependency, not the source.
    - next: review
  timestamp: 2026-10-09T16:36:57.415786+00:00
- actor: claude-code
  id: 01m4grdhaxxy8wf9cpe1cgyegv
  text: |-
    ### commit — changed
    - evidence: commit subject "feat(marketplace)!: load skills and agents by folder scan, remove catalog files"
    - next: none. Tests were green before the commit (Marketplace 381 tests, core 913 tests).
  timestamp: 2026-10-09T16:37:22.909281+00:00
position_column: doing
position_ordinal: '80'
title: 'Marketplace: load skills and agents by a folder scan, with no catalog files, and make agents folders (agents/<name>/AGENT.md)'
---
## Problem

The user approved this change on 2026-10-09. A marketplace is only a folder. The Marketplace module must find skills and agents by a scan. It must not read catalog files.

User decisions:
1. Scan only. The module stops reading catalog files. The user's words: "a marketplace is -- just a folder in my mind, and scanning finds that we need" and "needing a json file to 'match' the file layout is needless redundancy".
2. Agents are folders, the same as skills: `agents/<name>/AGENT.md`. AGENT.md holds the YAML frontmatter and the body. The other files in the folder are the resources of the agent. The folder name is the agent id.
3. Clean break: an old single file `agents/<id>.md` does not load. It gives one warning. The warning tells the user to move it to `agents/<id>/AGENT.md`.

This change is breaking (`feat!`).

## Work

### CatalogResolver
- [x] Remove the reads of `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` (`catalogPaths`).
- [x] Remove the plugin entries, the `skills` and `agents` lists, the renames and the remote-plugin path.
- [x] Remove `MarketplaceCatalog` and the types that only the catalog uses.

### The scan
- [x] A folder that holds the layout document (SKILL.md, from `MarketplaceLayout.documentName`) is a skill. The folder name is the skill name.
- [x] A folder that holds AGENT.md is an agent. Add a constant for AGENT.md next to `MarketplaceLayer.agentsDirectoryName`.
- [x] Do not scan into an entry folder. Its files are its resources.
- [x] Skip `layout.excludedDirectoryNames` (.git, node_modules).
- [x] Remove the `maximumScanDepth` limit of 3, or set a large limit. The layout `plugins/x/skills/y/SKILL.md` (depth 5) must load. The fixture `Examples/agent-library/marketplace` uses `plugins/<name>/{skills,agents}/`.
- [x] A folder that holds both SKILL.md and AGENT.md gives one warning. Load neither.
- [x] When two entries of the same kind have the same name, the shallower entry wins. If the depth is the same, the first path in path order wins. Each entry that loses gives one warning.
- [x] The skill name `agents` stays reserved.
- [x] An old single file `agents/<id>.md` gives one warning and does not load.

### SkillSelection
- [x] Remove `.plugins(_:)`. Keep `.all` and `.skills(_:)`.
- [x] `.all` takes all the agents. `.skills(_:)` takes no agents, as now.

### SnapshotWriter
- [x] Skills go to `<snapshot>/<name>/`, as now.
- [x] Copy each agent folder as a tree to `<snapshot>/agents/<name>/`. Use the same policy limits as for a skill folder. This replaces `copyAgents` (`SnapshotWriter.swift:211`).
- [x] Partials: copy the `_partials` folder of each folder from the root down to each selected entry. Keep the current specificity rules.

### Tests, docs and fixtures
- [x] Update the tests for the scan, the selection, the snapshot and the warnings.
- [x] Update the docs (README, CHANGELOG, plan.md as necessary).
- [x] Update the marketplace fixtures to the folder format, with no catalog files.

## Who waits on this
- FoundationModelsAgents: its loader change to `agents/<id>/AGENT.md` depends on this task (task ^k542qak on its board).
- swissarmyhammer/skills (`../skills`, session skills-79): the repo has no catalog files and has `agents/general-purpose/AGENT.md` on branch `code-context`. That agent does not load until this change is in.
- FoundationModelsSkills (session foundationmodelsskills-be): it uses `MarketplaceLayout` and `SkillSelection`. `.plugins` goes away.

When this change is in, tell the sessions foundationmodelsagents-3d and skills-79.