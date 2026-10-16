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
position_column: todo
position_ordinal: '80'
title: A cancel of one background run gives its waiting call a tool result, not a thrown CancellationError
---
A background call waits up to its settle period for its run. When something cancels only that run (`RunPlane.cancel(completionToken:)`, for example from `ToolContext.cancel`), the body ends with `CancellationError`. `BackgroundToolRunner` gives that error back to the waiting call, `ToolCallResult` throws it again unchanged, and the model call of the session fails. The caller was not cancelled, so the answer must not stop. The rule: a call stops only for its own cancel.

- [ ] When the run settles inside the settle period with `CancellationError` and the task of the waiting call is not cancelled, the call returns a tool result that says the run was cancelled. The model reads it, and the answer goes on.
- [ ] When the task of the waiting call is cancelled, the call still throws `CancellationError`.
- [ ] `ToolCallResult` throws a `CancellationError` again only when the task of the call is cancelled. Each other `CancellationError` becomes the text of a failure.
- [ ] Doc comments state the rule.
- [ ] Fixed-order tests for both cases. They fail on the old code. No clock, sleep, poll, retry or time limit.
- [ ] One full test run. The change is additive. Push when green, and report the head.

#defect