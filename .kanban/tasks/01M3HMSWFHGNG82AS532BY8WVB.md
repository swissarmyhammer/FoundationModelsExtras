---
assignees:
- claude-code
depends_on:
- 01M3HMSR0XDGD54R903GZHCJP3
position_column: todo
position_ordinal: '8580'
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
- [ ] Test: an `OperationTool` with one background op and one synchronous op; the background op returns a pending token, the synchronous op returns its real result in-band.
- [ ] Test: an operation with no declared mount is synchronous.
- [ ] Test: the macro accepts the mount value and the generated code compiles (macro expansion test, as the existing macro tests do).
- [ ] `swift build` 0 warnings; `swift test` passes.

#tool-hosting #cross-repo