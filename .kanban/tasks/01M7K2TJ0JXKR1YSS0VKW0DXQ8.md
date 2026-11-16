---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Operations: key-fit inference chooses only an operation that declares itself safe to infer; an op-less call that fits only other operations gets an error that lists them'
---
## Why

Key-fit inference in `OperationResolver` runs the one operation whose parameters fit the keys of a payload that has no `op`. FoundationModelsAgents found that the op-less call `{"name": X}` to its agents tool fitted only `remove agent`, and the tool removed the agent. Each tool that writes (skills, MCP servers, settings, kanban, sessions and more) can have the same problem. An operation that writes, removes or has another side effect must run only when the call names it.

## What

In `Sources/Operations`:

- `OperationDefinition` gets `static var isInferable: Bool { get }`. A protocol extension gives `false`. The doc tells that `true` is only for an operation that has no side effect (it only reads), and that key-fit inference and `defaultOp` choose only such operations.
- `AnyOperation` and `OperationResolver.OpCandidate` carry the flag.
- `inferredOpString(fromKeysOf:among:)` considers only the candidates with `isInferable == true`. One inferable fit runs. Several inferable fits use `defaultOp` when it is one of them.
- When the payload has no usable `op` and the key fit gives no inferable operation, `OperationTool` answers with a corrective error. The error tells the caller to name the operation in `op`, lists the operations whose parameters fit the keys (when there are some), and lists all valid operations. Thus a call that fits only `remove agent` does not run, and the model sees `remove agent` as a choice to name.
- An explicit `op` does not change. The per-tool `inferOp` hook does not change: it is code of the tool author, who chooses its op. Document this in the hook doc, and tell that a hook must not give an op that writes unless the tool author accepts that risk.
- The `@Operation` macro: if it is simple, let it take an argument for the flag. Otherwise a type sets `static let isInferable = true` itself. Document the way in `docs/GUIDE.md`, and update the key-fit text there.

## Acceptance

- [ ] Tests, written before the code: a tool with a read-only inferable op and a destructive op that is not inferable. An op-less call that fits only the destructive op does not run it (a counter in the context stays at zero) and gets the corrective error that names it. An op-less call that fits only the inferable op runs it. A call that fits both runs the inferable op. An explicit `op` of the destructive op still runs it. `defaultOp` that names a non-inferable op is not used for inference. The default of `isInferable` is `false`.
- [ ] Change the existing key-fit tests (`Tests/OperationsTests/OperationArgumentToleranceTests.swift`) so their read-only operations declare `isInferable = true`.
- [ ] Before the push, search the other packages under /Users/wballard/github/swissarmyhammer (Multitool, FoundationModelsSkills, FoundationModelsAgents, ACPAgent, Router, TestudoApp) for tests and tools that depend on key-fit inference. Report each operation that must now declare `isInferable = true` to keep its inference, for its owner.
- [ ] `swift test` is green with no compiler warnings.

#operations #safety