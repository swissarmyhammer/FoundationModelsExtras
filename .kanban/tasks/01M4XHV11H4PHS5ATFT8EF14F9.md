---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xm8hy85bd2z6scycv5ea19
  text: |-
    Research done.
    - RunPlane keeps pending elicitations with an id, a mode and a ticket only. No run token. ToolContext.elicit calls RunPlane.awaitAnswer.
    - A background run: the token of its ToolContext is the token of the run on the run plane (BackgroundToolRunner).
    - A synchronous call: ToolRun makes a new token that names no run on the run plane. A synchronous call that a run mounts through ToolContext.mount (for example an MCP call from a runCode snippet) asks its question with that new token. Thus the question must link to the token of the run that holds the call, not to the token of the inner call.
    - Plan: a pending elicitation keeps the run token. MountSite carries the token of the run that holds its synchronous calls. ToolContext keeps the run token of its questions. RunPlane exposes the pending elicitations with their run tokens, and the open runs that wait only for the user.
    - Limit: the run plane cannot see work that a run body does at the same time as a question (for example an un-awaited task). It sees questions and runs only.
  timestamp: 2026-10-14T16:34:53.000220+00:00
- actor: claude-code
  id: 01m4xmrcy1x3321cb76tj7xapx
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsExtras/Hosting/{RunPlaneActor,ElicitationDelivery,ToolContext,ToolMounting,ToolRun,RunToCompletionRunner,BackgroundToolRunner,ContextBindingTool}.swift; Tests/FoundationModelsExtrasTests/Hosting/{RunPlaneUserWaitTests (new, 6 tests),RunPlaneActorTests,ToolContextTests,MountFixtures,ToolHostingPublicSurfaceTests}.swift. `swift build --build-tests` passed with no package warnings. Filtered run of 8 hosting suites: 154 tests passed. Full `swift test`: 0 failures, all Swift Testing runs passed (largest run 1132 tests in 105 suites).
    - API: `RunPlane.openElicitations() -> [OpenElicitation]`, `RunPlane.runsWaitingOnlyForUser() -> [BackgroundRun]`, `public struct OpenElicitation { elicitationId: ULID; runToken: String }`. The internal `awaitAnswer(to:runToken:posting:)` now requires the run token.
    - Design: a question links to the run that holds the call. For a synchronous call that a run mounts (through `ToolContext.mount` or ContextBindingTool), this is the outer run, through `MountSite.holdingRunToken` and `ToolContext.holdingRunToken`. A background call links to its own token. A run waits only for the user when it is open and has one or more open questions.
    - Limit: the run plane cannot see work that a run body does at the same time as its question.
    - next: review
  timestamp: 2026-10-14T16:43:32.161807+00:00
position_column: doing
position_ordinal: '80'
title: Link each open question to the run token of the run that asked it
---
Source: elicitation-plan.md, Extras task 15. ACPAgent step 4 (T5) found this gap.

Link each open question (elicitation) to the run token of the run that asked it.

Expose the runs that wait only for the user. A run waits only for the user when all of its open work is questions to the user.

Router task 9 depends on this task. Router task 9: a run that waits only for the user does not count as work.

Do not start this task as part of the mail plan. This task is not in the mail plan. #elicitation-phase-1