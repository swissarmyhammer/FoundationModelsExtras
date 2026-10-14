---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4y2dpm030dger8aex13sr0b
  text: |-
    Research done.
    - RunPlane.cancel(completionToken:) runs the canceler only. The questions of the run stay open. A canceler that waits for the body does not end while the body waits in awaitAnswer.
    - RunPlane.sweep cancels the runs first, then ends all questions with `.cancel` (no reason). The same order problem applies: a canceler that waits for a body that waits in awaitAnswer stops the sweep.
    - A synchronous call that a run mounts already asks with the token of the outer run (ToolContext.holdingRunToken, MountSite.held(by:settlingBy:)). Thus a match on Elicitation.runToken == completionToken also ends the questions of those inner calls. No new link is necessary.
    - Two existing sweep tests in RunPlaneActorTests expect `== .cancel`. They must change to the new reason.
    - Plan: add `public static let runCancelledReason = "run cancelled"`, a private helper that ends the questions that match a condition, call it in cancel before the canceler, and in sweep before each canceler and after the loop for the remaining questions.
  timestamp: 2026-10-14T20:42:21.696589+00:00
- actor: claude-code
  id: 01m4y2tez1wcmebcpycaj6j3td
  text: |-
    Implementation landed (not committed).
    - RunPlane: new `public static let runCancelledReason = "run cancelled"`. New private helpers `cancelQuestions(ofRun:)` and `cancelQuestions(where:)`.
    - `cancel(completionToken:)` ends the open questions of an open run before it awaits the canceler. A settled or unknown token does not touch any question.
    - `sweep()` ends the questions of each run before it awaits the canceler of that run, then ends each remaining question (for example a question of a host context token) with the same reason.
    - Doc comments: RunPlane.cancel, RunPlane.sweep, ToolContext.elicit, ToolContext.cancel. README: one new bullet in the tool hosting section.
    - Tests: new suite RunPlaneCancelledRunQuestionTests (cancel ends the question before the canceler; a question of another run stays open; cancel of a background run ends the question of a synchronous call that it mounted; sweep ends the question before the canceler). The asking run uses a canceler that waits for the answer of the body, so a wrong order hangs and the bounded wait fails the test. The two existing sweep tests in RunPlaneActorTests now expect `.cancel(reason: RunPlane.runCancelledReason)`. One plain-import test holds the value "run cancelled". `MountingElicitTool` moved from RunPlaneUserWaitTests into MountFixtures so two suites share it.
    - RED: 4 new tests and 2 changed sweep tests failed for the expected reason (cancel and sweep never returned, or the question stayed open). GREEN after the change.
    - Discovery for the Router: FoundationModelsRouter Tests/FoundationModelsRouterTests/SessionRunPlaneTests.swift expects `await rejected.value == .cancel` after `session.close()` (sweep). When the Router moves its Extras pin past this change, that expectation must become `.cancel(reason: RunPlane.runCancelledReason)`. The Router takes Extras by git URL, so nothing breaks before the pin moves. No public, SPI or internal API changed.
  timestamp: 2026-10-14T20:49:19.841126+00:00
- actor: claude-code
  id: 01m4y2tjv9qaswetffs98btez9
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift, Sources/FoundationModelsExtras/Hosting/ToolContext.swift, README.md, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneCancelledRunQuestionTests.swift (new), Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift, Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneUserWaitTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolHostingPublicSurfaceTests.swift. Filtered `swift test --filter ...`: 8 tests passed. Full `swift test`: 1806 tests (131 + 40 + 44 + 26 + 410 + 1155) passed, 0 failures. One SwiftPM build note about the mlx bundle, also present before the change.
    - next: /review. The Router test SessionRunPlaneTests must expect the reason when the Router moves its Extras pin.
  timestamp: 2026-10-14T20:49:23.817632+00:00
depends_on:
- 01M4XZJ55X5PDN14JE3355FWDF
position_column: doing
position_ordinal: '80'
title: Resolve the open questions of a cancelled run with cancel and the reason "run cancelled"
---
Source: elicitation-plan.md, Extras task 17.

When a run is cancelled, resolve each open question of that run with `cancel` and the reason `"run cancelled"`. This applies to two paths:

- `cancel(completionToken:)`. Today the question of a cancelled run stays open.
- `RunPlane.sweep`. Today it cancels the question with no reason.

End the questions of the run before the code waits for the canceler. A run that waits in `awaitAnswer` cannot settle first, so if the code waits for the canceler first, the cancel does not end.

This task depends on Extras task 16 (a reason in elicitation decline and cancel). A Router card (a public SessionEvent `elicitationEnded`) depends on this task. Together they fix ACPAgent gap ^crjmk34.

Do not start this task until a person asks.

- [x] `cancel(completionToken:)` resolves the open questions of the run with `cancel` and the reason `"run cancelled"`.
- [x] `RunPlane.sweep` resolves the open questions with `cancel` and the reason `"run cancelled"`.
- [x] The questions end before the code waits for the canceler.
- [x] Add tests for both paths, with a run that waits in `awaitAnswer`. #elicitation-phase-1