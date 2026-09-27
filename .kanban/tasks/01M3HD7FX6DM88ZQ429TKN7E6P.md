---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hmtb93d3wvjzhh3hhjsb6t
  text: |-
    ### Added requirement (2026-09-27)
    This task now runs after the per-call mount tasks (01M3HMSR0XDGD54R903GZHCJP3 and 01M3HMSWFHGNG82AS532BY8WVB), so that the real-model tests cover the new behavior.
    - [ ] Test: one tool whose `mount(for:)` returns `.background` for one argument and synchronous for another, under a real model session. The model gets a pending token for the background call, and the real result in-band for the synchronous call.
    - [ ] Test: an `OperationTool` with one background operation and one synchronous operation, under a real model session.
  timestamp: 2026-09-27T14:38:00.995321+00:00
depends_on:
- 01M3HD6T6P13MA52XSVQ8EEGJF
- 01M3HMSWFHGNG82AS532BY8WVB
position_column: todo
position_ordinal: '8380'
title: 'Integration tests 4: real-model tests of tool hosting with a background tool'
---
## Why
The multitool uses tool hosting from Extras with a real model: the model calls a tool, the tool starts a background run, and the result comes back later. The unit tests drive `ToolContext`, `RunPlane` and the runners with scripted calls. These tests run them under a real FoundationModels `LanguageModelSession` in the nested `IntegrationTests/` package.

## What to do
Read how the Multitool and the Router integration suites drive a real session with mounted tools (`/Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/IntegrationTests/`, `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/IntegrationTests/`), and use the same model source (Apple Intelligence `.default` or the MLX model that those suites use; record the choice and why). Mount tools with the public Extras API only (`ToolMount`, `ToolMounting.makeWrapped`, `BackgroundTool`, `ToolContext`, `RunPlane`).

## Tests to add
- [ ] Run to completion: the model calls a mounted in-band tool, the tool reads `ToolContext.current`, posts progress, and returns; the model's answer uses the tool result.
- [ ] Background run: the model calls a `BackgroundTool`; the tool returns a pending envelope at once; the run settles later; `RunPlane.wait` gives the terminal; the settlement observer receives it.
- [ ] Grace wait: a fast background run settles inside the grace time, so the model gets the result inline and no pending envelope.
- [ ] Cancel: `RunPlane` cancel of a running background run gives the canceler's outcome, and the run settles with that outcome.
- [ ] Timeout: a mounted tool with a short timeout that ignores cancel gives `ToolMountError.timedOut` to the model at the deadline, and the model call does not hang.
- [ ] Failure delivery: a tool that throws gives the model a failure result, not a thrown error, and the session continues.
- Give each test a time limit. Simple test code; no lock/semaphore/gate types.

## Acceptance criteria
- [ ] `swift test --package-path IntegrationTests` passes on this machine, 3 runs in a row.
- [ ] The root `swift test` is unchanged and passes.

#integration-tests