---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'Tool hosting 6: a tool chooses background or synchronous for each call'
---
## Why
User direction (relayed 2026-09-27): "it's stupid that you made the 'tool' require being all background or not rather than the individual operation" and "list, check, cancel operations should be synchronous, meaning in their implementation you do not return until you get results. YOU have the choice to return a background token or not."
Today `ToolMounting.makeWrapped` (Sources/FoundationModelsExtras/Hosting/ToolMounting.swift) reads `(typed as? any BackgroundTool)?.mount ?? configuration` ONE time for the whole tool. The FoundationModelsAgents `agents` tool has 4 ops: `start agent` must return a background token, and `list`, `check`, `cancel` must run in-band and return their real result. Today the only way is to mount the whole tool `.background` and let fast ops settle inside `inlineSettleGrace`, which is a timeout, not a choice.

## What to do
1. `BackgroundTool` gets `func mount(for arguments: GeneratedContent) -> ToolMount`, with a default implementation that returns `mount`. Every current tool keeps its behavior.
2. The mounting code asks for the mount of EACH call, before the call runs:
   - A synchronous call runs in-band and returns its real output. There is no grace wait.
   - A background call returns the pending envelope, is tracked in the `RunPlane`, and its terminal goes to the sink as staged mail, the same as a background call today.
3. `ToolContext.mount(_:op:as: .background)` from inside a synchronous call: the started run must be a full background run whose terminal is POSTED to the session sink as staged mail (so it wakes the next submission), not only journaled. First check how a nested run reports its terminal in Extras today; then make it the same as a top-level background run.
4. Keep it simple: one decision point for each call, no new lock/semaphore/gate types, short doc comments. Update the README "Tool hosting" section.

## Acceptance criteria
- [ ] Test: a tool whose `mount(for:)` returns `.background` for one argument and synchronous for another; each call gets the correct behavior.
- [ ] Test: the synchronous call returns its real output also when it takes longer than `inlineSettleGrace`.
- [ ] Test: the background call returns a token also when its work ends at once.
- [ ] Test: a nested `.background` mount from a synchronous call posts its terminal to the sink as staged mail.
- [ ] Test: a tool with no `mount(for:)` override behaves as before (the existing tests pass with no change).
- [ ] `swift build` 0 warnings; `swift test` passes.

#tool-hosting #cross-repo