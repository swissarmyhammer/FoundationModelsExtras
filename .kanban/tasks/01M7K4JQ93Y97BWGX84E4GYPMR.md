---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Operations: the default verb alias `remove` → `delete` hides an operation whose verb is `remove`, so an explicit `op` cannot name it'
---
## Why

`OperationResolver.matchOpString(_:against:)` applies `verbAliases` before it compares the verb. The default table maps `remove` → `delete`. So with the default resolver, the explicit call `{"op": "remove entry", "name": "x"}` to a tool whose operation is `remove entry` gets "Unknown operation". The same is true for each verb that is a key of the default table (`create`, `new`, `show`, `read`, `fetch`, `remove`, `rm`, `del`).

Tools work around it today: `MCPServersTool` (FoundationModelsMultitool) adds `"remove": "remove"` and `"show": "show"`, and `AgentsTool` (FoundationModelsAgents) maps `remove` to its own verb. A new tool that does not know this cannot be called by the name of its operation.

This is more important now: key-fit inference no longer runs an operation that is not inferable, and the corrective error tells the caller to name the operation in `op`. When that name is `remove …`, the named call fails too.

## What

- In `Sources/Operations/OperationResolver.swift`, an exact verb/noun match of a registered operation wins before an alias is applied. An alias applies only when the verb, as given, is not the verb of a candidate with that noun.
- Same rule for the noun aliases and for the compact and one-word paths.

## Acceptance

- [ ] Test, written before the code: with the default resolver, `{"op": "remove entry"}` runs `remove entry`.
- [ ] Test: `{"op": "delete entry"}` still runs `delete entry` when the tool has it, and `{"op": "remove entry"}` still runs `delete entry` when the tool has no `remove entry`.
- [ ] `swift test` is green with no compiler warnings.

#operations