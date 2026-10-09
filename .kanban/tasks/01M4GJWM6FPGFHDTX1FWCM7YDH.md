---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
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
- [ ] Remove the reads of `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` (`catalogPaths`).
- [ ] Remove the plugin entries, the `skills` and `agents` lists, the renames and the remote-plugin path.
- [ ] Remove `MarketplaceCatalog` and the types that only the catalog uses.

### The scan
- [ ] A folder that holds the layout document (SKILL.md, from `MarketplaceLayout.documentName`) is a skill. The folder name is the skill name.
- [ ] A folder that holds AGENT.md is an agent. Add a constant for AGENT.md next to `MarketplaceLayer.agentsDirectoryName`.
- [ ] Do not scan into an entry folder. Its files are its resources.
- [ ] Skip `layout.excludedDirectoryNames` (.git, node_modules).
- [ ] Remove the `maximumScanDepth` limit of 3, or set a large limit. The layout `plugins/x/skills/y/SKILL.md` (depth 5) must load. The fixture `Examples/agent-library/marketplace` uses `plugins/<name>/{skills,agents}/`.
- [ ] A folder that holds both SKILL.md and AGENT.md gives one warning. Load neither.
- [ ] When two entries of the same kind have the same name, the shallower entry wins. If the depth is the same, the first path in path order wins. Each entry that loses gives one warning.
- [ ] The skill name `agents` stays reserved.
- [ ] An old single file `agents/<id>.md` gives one warning and does not load.

### SkillSelection
- [ ] Remove `.plugins(_:)`. Keep `.all` and `.skills(_:)`.
- [ ] `.all` takes all the agents. `.skills(_:)` takes no agents, as now.

### SnapshotWriter
- [ ] Skills go to `<snapshot>/<name>/`, as now.
- [ ] Copy each agent folder as a tree to `<snapshot>/agents/<name>/`. Use the same policy limits as for a skill folder. This replaces `copyAgents` (`SnapshotWriter.swift:211`).
- [ ] Partials: copy the `_partials` folder of each folder from the root down to each selected entry. Keep the current specificity rules.

### Tests, docs and fixtures
- [ ] Update the tests for the scan, the selection, the snapshot and the warnings.
- [ ] Update the docs (README, CHANGELOG, plan.md as necessary).
- [ ] Update the marketplace fixtures to the folder format, with no catalog files.

## Who waits on this
- FoundationModelsAgents: its loader change to `agents/<id>/AGENT.md` depends on this task (task ^k542qak on its board).
- swissarmyhammer/skills (`../skills`, session skills-79): the repo has no catalog files and has `agents/general-purpose/AGENT.md` on branch `code-context`. That agent does not load until this change is in.
- FoundationModelsSkills (session foundationmodelsskills-be): it uses `MarketplaceLayout` and `SkillSelection`. `.plugins` goes away.

When this change is in, tell the sessions foundationmodelsagents-3d and skills-79.