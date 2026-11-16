---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7k4k43tcz8p5sfvndc8pas5
  text: |-
    Research and implementation notes.

    - Design: `OperationDefinition.isInferable` (protocol extension default `false`), carried by `AnyOperation.isInferable` and `OperationResolver.OpCandidate.isInferable`. The resolver now returns `OpMatch` (`.matched`, `.unknown`, `.unnamed(fitting:)`) from `matchedOp(for:among:)`. `fittingCandidates` gives all fits (inferable or not, for the error); `inferredOpString(among:)` considers only inferable fits, and `defaultOp` is matched only against inferable fits.
    - New error case `OperationError.unnamedOperation(fitting:valid:)`. Text: "No operation is named. Name the operation in `op`. Operations whose parameters fit the given keys: X. Valid operations: …". The fits sentence is left out when no operation fits. An explicit `op` or an `inferOp` proposal that matches nothing still gives "Unknown operation.".
    - `@Operation` takes `isInferable: Bool = false`; the macro emits `static let isInferable: Bool = …` when the argument is present (same pattern as `mount`, one shared helper `optionalStaticText`).
    - Behavior change in the skills mirror tests: `{"id", "path"}` fitted `read resource` and `run script` and was unknown; now only `read resource` is inferable, so it runs `read resource`.
    - Discovery (new task ^e4gypmr): the default verb alias `remove` → `delete` is applied before the exact verb compare, so with the default resolver `{"op": "remove entry"}` is "Unknown operation" for a tool whose op is `remove entry`. The fixture of the new tests uses `delete entry` for this reason. FoundationModelsAgents and MCPServersTool add their own `remove` alias to work around it.
  timestamp: 2026-11-16T21:35:43.226263+00:00
- actor: claude-code
  id: 01m7k4p4mcc59jdvnvb211cydp
  text: |-
    Search of the other packages (read only). Paths are under /Users/wballard/github/swissarmyhammer.

    FoundationModelsSkills (`defaultOp: "use skill"`, `Sources/FoundationModelsSkills/Operations/SkillsTool.swift`):
    - Must declare `isInferable = true`: `UseSkill` (`Operations/UseSkill.swift`), `SearchSkill`, `ListSkill`, `ReadResource` (`Resources/ReadResource.swift`). Can also declare it (not chosen alone today): `ListResource`, `ShowMarketplace`, `ListMarketplace`.
    - `PlainTextMarker` (`Operations/PlainTextOperations.swift`) forwards `verb`, `noun` and `parameterMetadata` of its `Target`. It must also forward `static var isInferable: Bool { Target.isInferable }`, or the plain-text matcher stops inferring.
    - Tests that break until both changes land: the four op-less tests in `Tests/FoundationModelsSkillsTests/InferredOpPlainTextTests.swift` (`{"id"}`, `perform({"id"})`, `{"id","arguments":[]}`, `{"arguments":{"id"}}`).
    - Caveat: in `.open` mode, `use skill` renders the skill body and runs its shell injections, so an op-less `{"id"}` can run commands.
    - Destructive operations that key-fit can reach today: `RemoveSkill` (`{"id","layer"}` deletes the skill), `EditSkill` (`{"id","content","path"}`), `RunScript` (`{"id","path","arguments"}` or `{"id","path","timeout"}` starts a process), `AddMarketplace` (`{"url", …}`), `EditMarketplace` (`{"id","url"}`, `{"id","ref"}` and more).
    - Docs that state a false claim today: `docs/operations.md` ("an inference never writes") and the comment on `SkillsTool.makeResolver`.
    - Behavior change: `{"id","path"}` in open mode now runs `read resource` (before: it tied with `run script` and was unknown).

    FoundationModelsMultitool (`SessionsTool`, `MCPServersTool`, no `defaultOp`, no `inferOp`):
    - Must declare `isInferable = true` to keep inference: `ListSessions` (`Capabilities/Sessions/SessionsToolOperations.swift`). Can also declare (changes behavior: a key set that is unknown today becomes a read): `CheckSession`, `ShowMCPServer`.
    - Tests that break: none (all tests give an explicit `op`).
    - Destructive operations that key-fit can reach today: `StartSession` (`{"message"}`, `{"prompt"}`, `{"text"}` start a session), `SendMessage` (`{"to","message"}`), `ReplyMessage` (`{"id","message"}`), `RenameSession` (`{"name"}` renames the own session), `EditMCPServer` (any set with `name` and `newName`). FoundationModelsACPAgent mounts these tools at the top level, so these are live in ACP sessions.

    FoundationModelsAgents (`AgentsTool`, `inferOp: resolverProposal(of:)`):
    - The hook never returns nil (it gives `""`), so key-fit is never reached. No flag is needed and no test breaks. `noOpThatFitsNoOneOpIsNotInferred` keeps "Unknown operation." because a hook proposal that matches nothing stays `.unknown`.
    - For later safety, the read-only operations are `ListAgents`, `FindAgents`, `CheckAgent`, `ListSchedules`, `GetSchedule`.

    FoundationModelsACPAgent, FoundationModelsRouter, TestudoApp: no `OperationResolver` in production code; Router test fixtures always give `op`. No flags needed and no tests break.
  timestamp: 2026-11-16T21:37:22.060795+00:00
- actor: claude-code
  id: 01m7k4p7tykw139vynsq78jzz1
  text: |-
    ### implement — changed
    - evidence: `swift test --filter Operations` green (169 + 43 + 46 + 1 tests); full `swift test` exit 0 (1949, 451, 169, 46, 43, 35, 26 tests passed), no compiler warnings. Files: Sources/Operations/OperationDefinition.swift, AnyOperation.swift, OperationError.swift, OperationResolver.swift, OperationTool.swift, Operations.swift; Sources/OperationsMacros/OperationsMacros.swift; Tests/OperationsTests/OperationInferenceSafetyTests.swift (new), OperationArgumentToleranceTests.swift; Tests/OperationsMacrosTests/OperationMacroTests.swift, MountCompileTests.swift; docs/GUIDE.md.
    - next: /review. Other packages need follow-up work by their owners (see the search comment). New task ^e4gypmr for the verb-alias problem.
  timestamp: 2026-11-16T21:37:25.342634+00:00
position_column: doing
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

- [x] Tests, written before the code: a tool with a read-only inferable op and a destructive op that is not inferable. An op-less call that fits only the destructive op does not run it (a counter in the context stays at zero) and gets the corrective error that names it. An op-less call that fits only the inferable op runs it. A call that fits both runs the inferable op. An explicit `op` of the destructive op still runs it. `defaultOp` that names a non-inferable op is not used for inference. The default of `isInferable` is `false`.
- [x] Change the existing key-fit tests (`Tests/OperationsTests/OperationArgumentToleranceTests.swift`) so their read-only operations declare `isInferable = true`.
- [x] Before the push, search the other packages under /Users/wballard/github/swissarmyhammer (Multitool, FoundationModelsSkills, FoundationModelsAgents, ACPAgent, Router, TestudoApp) for tests and tools that depend on key-fit inference. Report each operation that must now declare `isInferable = true` to keep its inference, for its owner.
- [x] `swift test` is green with no compiler warnings.

#operations #safety