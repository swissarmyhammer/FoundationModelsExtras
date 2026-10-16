---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m510peafq92t1s1z36x5sbj1
  text: |-
    ### design — accepted by the peer
    - A: BackgroundToolRunner.start gives a fixed tool result text when the run settles inside the settle period with CancellationError and the task of the waiting call is not cancelled. The text: "The run <completionToken> of <tool> was cancelled before it ended, so it gives no result." It comes from one internal static function.
    - B: ToolCallResult.init(catching:) throws a CancellationError again only when Task.isCancelled. Each other CancellationError becomes the failure text.
    - No reason parameter on cancel(completionToken:). The text says "cancelled" only.
    - Tests: (1) a run cancel inside the settle period, with the caller not cancelled, gives the text; (2) a cancelled caller throws CancellationError; (3) ToolCallResult with each case.
    - Order: start after ^vhmp05a is pushed. Report the head to the peer, because ACPAgent then changes its run-cancel tests to expect end_turn.
  timestamp: 2026-10-16T00:09:54.255014+00:00
- actor: claude-code
  id: 01m5143ncrb10k1dkg113vrx07
  text: |-
    ### research
    - The cooperative canceler of the run plane calls `work.cancel()` on the body task and returns at once. The cancel handler of `ToolRun.settle` then cancels the call task in the same step. Thus a tool that calls `ToolContext.cancel(completionToken:)` with its own token, then `Task.checkCancellation()`, ends with `CancellationError` in a fixed order, with no wait.
    - `RunPlane.wait` gives `.cancelled` when the task of the waiting call is cancelled before the run settles. Then the call answers with the pending envelope. This path does not change.
    - A fixed-order test of a cancelled caller with a settled run: the runner calls `withdrawStagedEvents` on a `StagedEventWithdrawing` sink after the wait settles and before it makes the answer. That call runs in the task of the call, so a sink that cancels the current task there cancels the caller at a known point.
    - Two tests in ToolFailureDeliveryTests state the old rule (a `CancellationError` always throws): "a body that throws a CancellationError throws it again" and "a String-output tool that ends as cancelled still throws the cancellation". They must now run in a cancelled task.
  timestamp: 2026-10-16T01:09:33.208995+00:00
- actor: claude-code
  id: 01m5149s8s92wcjn0sr6b419mh
  text: |-
    ### RED (old code)
    - `swift test --filter 'runCancelledInsideTheGraceGivesAToolResult|cancelledCallOfACancelledRunThrowsTheCancellation|ToolFailureDeliveryTests'`: 16 tests, 2 issues.
    - Fails: "a run that a cancel of only that run ends inside the grace gives the model a tool result ..." (Caught error: CancellationError()), and "a body that throws a CancellationError while the task of the call is not cancelled gives the failure text" (Caught error: CancellationError()).
    - Passes on the old code, as expected: the two cancelled-caller tests (the rule that a cancel of the call throws does not change).
    - New fixtures in MountFixtures: `SelfCancellingTool` (cancels its own run through `ToolContext.cancel`, then `Task.checkCancellation()`) and `CallCancellingSink` (cancels the task of the call in `withdrawStagedEvents`).
  timestamp: 2026-10-16T01:12:53.785592+00:00
- actor: claude-code
  id: 01m514j9a2snvhfvgeh0jb6nk0
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift (internal `cancelledRunText(completionToken:tool:)` and private `modelResult(of:completionToken:tool:)`; `start` passes the settled result through it; doc comments state the rule), Sources/FoundationModelsExtras/Hosting/ToolFailureDelivery.swift (`ToolCallResult.init(catching:)` throws a `CancellationError` again only `where Task.isCancelled`; enum, both `call` Throws lines and the init doc state the rule), README.md (the `ToolFailureDelivery` sentence of the tool-hosting section), Tests/.../Hosting/MountFixtures.swift (`CallCancellingSink`, `SelfCancellingTool`), Tests/.../Hosting/BackgroundToolRunnerTests.swift (2 new tests), Tests/.../Hosting/ToolFailureDeliveryTests.swift (1 new test; 2 tests of the old rule now run in a cancelled task).
    - RED: 16 tests, 2 issues (the two not-cancelled cases). GREEN (same filter, one run): 16 tests passed.
    - Full `swift test` (one run): 1176 tests in 113 suites passed, exit 0. No compiler warnings. The only "warning:" line is the build-system note "missing creator for mutated node" for the mlx-swift_Cmlx bundle; it was in the RED run before the source change too.
    - No public API change. `RunToCompletionRunner` does not change.
    - Not done here, by instruction: commit and push. The last subtask stays open.
    - next: /review
  timestamp: 2026-10-16T01:17:32.354778+00:00
position_column: doing
position_ordinal: '80'
title: A cancel of one background run gives its waiting call a tool result, not a thrown CancellationError
---
A background call waits up to its settle period for its run. When something cancels only that run (`RunPlane.cancel(completionToken:)`, for example from `ToolContext.cancel`), the body ends with `CancellationError`. `BackgroundToolRunner` gives that error back to the waiting call, `ToolCallResult` throws it again unchanged, and the model call of the session fails. The caller was not cancelled, so the answer must not stop. The rule: a call stops only for its own cancel.

- [x] When the run settles inside the settle period with `CancellationError` and the task of the waiting call is not cancelled, the call returns a tool result that says the run was cancelled. The model reads it, and the answer goes on.
- [x] When the task of the waiting call is cancelled, the call still throws `CancellationError`.
- [x] `ToolCallResult` throws a `CancellationError` again only when the task of the call is cancelled. Each other `CancellationError` becomes the text of a failure.
- [x] Doc comments state the rule.
- [x] Fixed-order tests for both cases. They fail on the old code. No clock, sleep, poll, retry or time limit.
- [ ] One full test run. The change is additive. Push when green, and report the head.

#defect