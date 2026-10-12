---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4qwnd8ms1n0vy58085fmd6t
  text: |-
    Research: the old text is only in ToolHostingFixtures.swift (startedRunInstruction override on ArchiveScanTool and EndlessScanTool, WaitTool with "Call wait again") and ToolHostingIntegrationTests.swift (SessionInstructions.callingBoth says "call the wait tool"; WaitTool is mounted in perCallMountOfOneTool and perCallMountOfAnOperationTool). No "Do not answer yet" text is in IntegrationTests sources. ToolSession.Answer.toolOutputs holds every tool output of the session so far, so a follow-up turn in the same session keeps the envelopes.

    Decision (user, through the question tool): option A. The test host injects the result as a new message, the same as a real session. Plan: delete WaitTool; the per-call tests answer the prompt, then for each pending envelope that is not injected yet, wait for the run on the run plane and send its terminal detail as a new prompt in the same session, until no pending envelope is left; the final answer must hold the background code. ArchiveScanTool and EndlessScanTool use the default collectInstruction (it ends with PendingRunEnvelope.pendingWorkInstruction), and the tests check that the envelope `next` holds that text.
  timestamp: 2026-10-12T11:06:16.212889+00:00
- actor: claude-code
  id: 01m4qwzzt57xjxqxqm48cx6vnh
  text: |-
    Implementation landed.
    - ToolHostingFixtures.swift: deleted WaitTool and the private startedRunInstruction text. ArchiveScanTool and EndlessScanTool now use the default collectInstruction, which ends with PendingRunEnvelope.pendingWorkInstruction. JobTool got named codes (scanCode, countCode); scanResult and countResult are built from them.
    - ToolHostingIntegrationTests.swift: SessionInstructions.callingBoth no longer names a wait tool; it says that the background result comes later in a new message. New HostMessage.settledRun(completionToken:terminal:) gives the injected message. New answerInjectingSettledRuns(...) runs one session: it answers the prompt, then for each pending envelope that has no injection yet it waits for the run on the run plane and sends the terminal detail as a new prompt, until each envelope has one injection. expectPerCallMounts now takes codes and also checks that the last answer text holds the background code (only the injected message gave that code to the model). backgroundToolSettlesAfterItsEnvelope and cancelSettlesTheRunWithTheCancelerOutcome check that envelope.next holds PendingRunEnvelope.pendingWorkInstruction. New pendingTokens(in:) helper is shared by the injection loop and expectPerCallMounts.
    - Note for the acceptance grep: a case-insensitive search for "wait tool" matches `await ToolSession` in code, and "call wait" matches "evict call waits" in EvictionWaitTests.swift. These are not model-facing text. No WaitTool, no "call the wait tool", no "Call wait again" and no "Do not answer yet" text is left in IntegrationTests sources.
    - Results: `swift build --build-tests --package-path IntegrationTests` clean (only the mlx-swift "missing creator for mutated node" line). `swift test --package-path IntegrationTests --filter ToolHostingIntegrationTests`: 8 tests passed. `swift test --package-path IntegrationTests`: 35 tests in 9 suites passed, no other warning.

    ### implement — changed
    - evidence: 2 files — IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ToolHostingFixtures.swift, IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ToolHostingIntegrationTests.swift; swift test --package-path IntegrationTests: 35 passed, 0 failed
    - next: review
  timestamp: 2026-10-12T11:12:02.885881+00:00
- actor: claude-code
  id: 01m4qx79t2rb5tg2t49ja9x88f
  text: |-
    ### review — clean
    - evidence: review sha 45836fd~1..45836fd — 0 findings (0 confirmed, 0 refuted, 7 attempted, 0 failed). 2 files reviewed; 4 .kanban/ files not reviewed (.reviewignore). No prior Review Findings sections.
    - next: none. The task moved to done.
  timestamp: 2026-10-12T11:16:02.498046+00:00
- actor: claude-code
  id: 01m4qx7b13yvbmveskk6wbvrwj
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files
    - test: green — swift test, 979 passed; IntegrationTests ToolHosting, 8 passed
    - commit: 45836fd
    - review: clean — 0 findings
  timestamp: 2026-10-12T11:16:03.747862+00:00
position_column: done
position_ordinal: f280
title: 'IntegrationTests: remove the model-facing wait tool and its "call wait again" text from the tool-hosting fixtures'
---
## Why

Task ^ebz3m7y replaced the wait-tool text in `PendingRunEnvelope.defaultCollectInstruction(forCompletionToken:)` with `PendingRunEnvelope.pendingWorkInstruction`. The session injects the result of a background run as a new message, so the model must call no tool to wait.

The nested `IntegrationTests` package was out of the scope of that task. It still has the old text:
- `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ToolHostingFixtures.swift`: two tools give their own `collectInstruction(forCompletionToken:)`, and a wait tool answers "The run continues. Call wait again with the same completionToken."
- `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ToolHostingIntegrationTests.swift`: the session instructions tell the model to "call the wait tool" when a run continues in the background.

## What to do

1. Decide with the user how the real-model tests must collect a background result now. One possibility: the test host injects the result as a new message, the same as a real session.
2. Remove the model-facing wait tool and the "wait tool" / "call wait" text from the fixtures and the session instructions.
3. Use `PendingRunEnvelope.pendingWorkInstruction` where a fixture needs the pending-work text.

## Acceptance criteria

- No "wait tool", "call wait" or "Do not answer yet" text in `IntegrationTests/`.
- `swift test --package-path IntegrationTests` passes with no warnings.