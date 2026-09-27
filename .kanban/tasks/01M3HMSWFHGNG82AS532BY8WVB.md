---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hrac4jazfvwh3yebehenaa
  text: |-
    Research done.
    - `Operations` depends on `FoundationModelsExtras`, thus `OperationTool` can conform to `BackgroundTool` directly. `Arguments` is `GeneratedContent`, thus `ToolMounting.backgroundDeclaration` reads it with no change.
    - Plan: `OperationDefinition.mount` (static, default `.synchronous`); `AnyOperation.mount` copies it; `OperationTool.mount(for:)` uses the private `matchOperation(for:)`, and gives `.synchronous` for an unknown op. The tool-level `mount` stays `nil`, thus `makeWrapped` keeps the host mount for the runner choice, and `ToolMounting.call` decides each call.
    - `@Operation` gets a `mount: ToolMount = .synchronous` argument. The macro emits `static let mount` only when the argument is present, thus each existing expansion stays the same.
    - `Operations` re-exports `ToolMount` as a typealias, the same pattern as `OperationEvent`, so that code that imports only `Operations` can name it.
    - Behavior change: an `OperationTool` that a host mounts as background now runs each call synchronously, unless the operation declares a background mount. This is the order of the card (default synchronous).
  timestamp: 2026-09-27T15:39:11.890232+00:00
- actor: claude-code
  id: 01m3hrnv5d39jf327x8cfhp20p
  text: |-
    Implementation landed (test first; the new tests failed to compile before the change: no `mount` argument, no `ToolMount` in `Operations`).
    - `OperationDefinition.mount` (default `.synchronous`), `AnyOperation.mount`, `OperationTool: BackgroundTool` with `mount(for:)` (unknown op gives `.synchronous`).
    - `@Operation(..., mount:)`: the macro emits `static let mount: ToolMount = <expr>` only when the argument is present, so each existing expansion test stays the same. `Operations.swift` now imports `FoundationModelsExtras`: a macro default argument (`= .synchronous`) needs the module of the type imported in that file, the typealias alone is not sufficient.
    - `Operations` re-exports `ToolMount` as a typealias (new file `Sources/Operations/ToolMount.swift`). A test file that imports both `Operations` and `FoundationModelsExtras` compiles with no ambiguity.
    - Docs: README tool-hosting bullet, new `docs/GUIDE.md` section, CHANGELOG entry with a migration note.
    - Discovery: the test fixture in `OperationsTests` mounts through the public `ToolMounting.makeWrapped` and `MountSite(sessionID:runPlane:sink:)`, thus it needs no `@testable` access to the core module.
  timestamp: 2026-09-27T15:45:27.725187+00:00
- actor: claude-code
  id: 01m3hrp34qbzm0qcb15bqvq2gk
  text: |-
    ### implement — changed
    - evidence: swift build 0 warnings; swift test 1365 tests pass (131+37+44+26+396+731), 0 failures. New tests: Tests/OperationsTests/OperationMountTests.swift (6), Tests/OperationsMacrosTests/MountCompileTests.swift (2), OperationMacroTests.mountArgumentSynthesizesTheMountStatic (1).
    - files: Sources/Operations/{ToolMount.swift (new), OperationDefinition.swift, AnyOperation.swift, OperationTool.swift, Operations.swift}, Sources/OperationsMacros/OperationsMacros.swift, README.md, docs/GUIDE.md, CHANGELOG.md.
    - next: review
  timestamp: 2026-09-27T15:45:35.895635+00:00
depends_on:
- 01M3HMSR0XDGD54R903GZHCJP3
position_column: doing
position_ordinal: '80'
title: 'Operations: each operation declares its mount, and OperationTool chooses it for each call'
---
## Why
An `OperationTool` has several operations in one tool. With per-call mounts (tool hosting 6), each operation must be able to say if it runs in the background or synchronously. Example: the FoundationModelsAgents `agents` tool: `start agent` is background; `list agents`, `check agent` and `cancel agent` are synchronous.

## What to do
Read the `Operations` module (Sources/Operations*, the `@Operation` macro in the macros target, `OperationTool`) first.
1. An operation can declare its mount: a `mount` value on the operation definition, settable through the `@Operation` macro. The default is synchronous.
2. `OperationTool` conforms to `BackgroundTool` and implements `mount(for arguments:)`: it reads the operation name from the arguments and returns that operation's mount. An unknown operation name is synchronous (the tool then reports its normal error in-band).
3. Keep it simple: no new lock/semaphore/gate types, short doc comments. Update the README part for operations.

## Acceptance criteria
- [x] Test: an `OperationTool` with one background op and one synchronous op; the background op returns a pending token, the synchronous op returns its real result in-band.
- [x] Test: an operation with no declared mount is synchronous.
- [x] Test: the macro accepts the mount value and the generated code compiles (macro expansion test, as the existing macro tests do).
- [x] `swift build` 0 warnings; `swift test` passes.

#tool-hosting #cross-repo