---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7mp0dyfm0930cjzp8pts6xf
  text: |-
    Iteration 1: Commit fe4fb8d. matchOpString compares the words as given first (two-token, joined, compact). It applies the verb and noun aliases only when that pass finds no match. The one-word path uses the same rule. New tests are in OperationResolverTests and OperationInferenceSafetyTests (through OperationTool.call). docs/GUIDE.md tells the rule. swift build is clean, with no warnings. Full swift test: 2729 tests in 7 runs pass.

    Review 2b8ee77..fe4fb8d: 5 findings.
    - [ ] OperationResolver.swift:335 code-hygiene/magic-numbers-swift: Magic numbers should be replaced by named constants.
    - [ ] OperationResolver.swift:370 reuse/reuse: separatedMatch repeats the loop of compactMatch. Move the shared loop into one helper with a comparison closure.
    - [ ] OperationResolver.swift:378 completeness/invariant-propagation: the two-token alias pass reads the raw verbAliases table, but the noun reads compactNounAliases. Look up the verb in compactVerbAliases. Add one test with a verb alias key that has an underscore, given as two tokens.
    - [ ] OperationResolver.swift:394 code-hygiene/magic-numbers-swift: Magic numbers should be replaced by named constants.
    - [ ] OperationInferenceSafetyTests.swift:149 reuse/reuse: makeTool(_:) copies makeEntryTool(defaultOp:). Give makeEntryTool an operations parameter with the four-operation list as default, delete makeTool.
  timestamp: 2026-11-17T11:59:19.503254+00:00
- actor: claude-code
  id: 01m7mp9ftbx0xwc0bwya86m8p5
  text: |-
    Iteration 2: Commit 42cc978 fixes all 5 findings of review 1.
    - [x] magic numbers (both findings): soleElement(of:) and verbAndNounTokenCount replace each number literal in OperationResolver.swift, also in inferredOpString and unwrappingArguments.
    - [x] reuse in separatedMatch and compactMatch: one helper firstMatch(of:against:aliased:comparing:).
    - [x] invariant-propagation: the two-token alias pass reads compactVerbAliases. New test multiWordVerbAliasKeyMatchesTwoTokensByTheSeparatedCompare.
    - [x] test helper reuse: makeEntryTool(operations:defaultOp:), makeTool is deleted.
    Full swift test: 2730 tests in 7 runs pass, no warnings.

    Review fe4fb8d..42cc978: 1 finding.
    - [ ] OperationResolver.swift:465 code-hygiene/idioms-swift: UseLetInEveryBoundCaseVariable: move this 'let' keyword inside the 'case' pattern, before each of the bound variables.
    Fix in progress: all three `case let .structure(properties, _)` in the file become `case .structure(let properties, _)`.
  timestamp: 2026-11-17T12:04:16.331352+00:00
- actor: claude-code
  id: 01m7mpcr0y7ar2z6x7rd1h1hfw
  text: |-
    Iteration 3: Commit 12c90d6 fixes the finding of review 2.
    - [x] code-hygiene/idioms-swift UseLetInEveryBoundCaseVariable: all three `case let .structure(properties, _)` in OperationResolver.swift are now `case .structure(let properties, _)`.
    Full swift test: 2730 tests in 7 runs pass, no warnings.
    Review 42cc978..12c90d6: 0 findings. The task is done.

    Behavior change for dependents: when a tool has an operation `X N`, an alias maps X to Y, and the tool also has `Y N`, the op `X N` now runs `X N`. Before, it ran `Y N`. A one-word op that names a verb or noun as given no longer goes through an alias. The identity entries `remove: remove`, `show: show`, `read: read` in MCPServersTool, AgentsTool, SessionsTool and SkillsTool are no longer necessary, but they do no harm.
  timestamp: 2026-11-17T12:06:03.038420+00:00
position_column: done
position_ordinal: fff080
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