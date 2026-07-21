---
comments:
- actor: claude-code
  id: 01ky31g4e1em18kc61az9ssxmx
  text: 'Starting implementation. Plan: add Examples/ExtrasDemo/Fixtures/agents/ fixture tree (own .git marker file, AGENTS.md at root, AGENT.md at agents/service/, CLAUDE.md alone at agents/service/api/ as the alias-only directory). Add DemoFixtures.agentsRepoRoot / agentsLeafDirectory. Add AgentsCommand.swift (extras-demo agents) printing "<relative-dir> -> <alias> (<path>)" per document, outermost-first. Register in main.swift subcommands. Add integration test to ExtrasDemoIntegrationTests.swift. Update README intro + Documentation section (three pillars -> four pillars, AgentsMd mention). TDD: writing the integration test first (will fail to compile/run until fixture+command exist).'
  timestamp: 2026-07-21T19:12:32.193904+00:00
depends_on:
- 01KY2FJM3T8PSR588BQ67W7ZJ6
position_column: doing
position_ordinal: '80'
title: extras-demo agents subcommand + integration test (plan §10)
---
Add the fourth pillar's demo lane per plan.md §10: an 'agents' subcommand on extras-demo that walks a checked-in fixture tree (extend Examples/ExtrasDemo fixtures with a nested repo-like tree containing AGENTS.md/AGENT.md/CLAUDE.md at different levels, including one alias-only directory) and prints each discovered document with the directory it governs and which alias matched — provenance made visible, same spirit as extras-demo stack. Mirror the existing ExtrasDemoIntegrationTests pattern: invoke the built extras-demo binary as a subprocess and assert on output. Also update README's pillar list to include AgentsMd. Depends on the AgentsMd implementation task (67w7zj6).