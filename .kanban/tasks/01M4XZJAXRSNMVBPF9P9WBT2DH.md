---
assignees:
- claude-code
depends_on:
- 01M4XZJ55X5PDN14JE3355FWDF
position_column: todo
position_ordinal: '8180'
title: Resolve the open questions of a cancelled run with cancel and the reason "run cancelled"
---
Source: elicitation-plan.md, Extras task 17.

When a run is cancelled, resolve each open question of that run with `cancel` and the reason `"run cancelled"`. This applies to two paths:

- `cancel(completionToken:)`. Today the question of a cancelled run stays open.
- `RunPlane.sweep`. Today it cancels the question with no reason.

End the questions of the run before the code waits for the canceler. A run that waits in `awaitAnswer` cannot settle first, so if the code waits for the canceler first, the cancel does not end.

This task depends on Extras task 16 (a reason in elicitation decline and cancel). A Router card (a public SessionEvent `elicitationEnded`) depends on this task. Together they fix ACPAgent gap ^crjmk34.

Do not start this task until a person asks.

- [ ] `cancel(completionToken:)` resolves the open questions of the run with `cancel` and the reason `"run cancelled"`.
- [ ] `RunPlane.sweep` resolves the open questions with `cancel` and the reason `"run cancelled"`.
- [ ] The questions end before the code waits for the canceler.
- [ ] Add tests for both paths, with a run that waits in `awaitAnswer`. #elicitation-phase-1