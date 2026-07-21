---
depends_on:
- 01KY2FJM3T8PSR588BQ67W7ZJ6
position_column: todo
position_ordinal: '8180'
title: extras-demo agents subcommand + integration test (plan §10)
---
Add the fourth pillar's demo lane per plan.md §10: an 'agents' subcommand on extras-demo that walks a checked-in fixture tree (extend Examples/ExtrasDemo fixtures with a nested repo-like tree containing AGENTS.md/AGENT.md/CLAUDE.md at different levels, including one alias-only directory) and prints each discovered document with the directory it governs and which alias matched — provenance made visible, same spirit as extras-demo stack. Mirror the existing ExtrasDemoIntegrationTests pattern: invoke the built extras-demo binary as a subprocess and assert on output. Also update README's pillar list to include AgentsMd. Depends on the AgentsMd implementation task (67w7zj6).