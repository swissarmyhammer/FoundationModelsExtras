---
assignees:
- claude-code
depends_on:
- 01M50MVD045658RXD65ASVTTYB
position_column: todo
position_ordinal: '80'
title: A host tool ends its own accepted URL flow, and the run plane posts an event when a URL flow completes
---
Source: elicitation-plan.md, task 8 (phase 3: the async question path).

Today `elicitation/complete` goes to the client at consent, because nothing on the tool side ends a URL flow.

- [ ] Send a design to the coordinating session, and get acceptance before code.
- [ ] A host tool can end its own accepted URL flow, for example with `ToolContext.complete(elicitationId:)`.
- [ ] When `RunPlane.complete(elicitationId:)` completes an accepted URL flow, from any source, the run plane posts a sink event (for example an `OperationEvent` of a new kind `elicitationCompleted` with the id), in the same way as the event of a new question today. Router can then report it.
- [ ] Additive public API only. Tell the coordinating session each public API change before the push.
- [ ] Fixed-order tests that fail on the old code. No clock, sleep, poll, retry or time limit.
- [ ] One full test run.

Start this task after the task that validates answers against the requested schema. FoundationModelsMultitool and FoundationModelsRouter follow after this task.

#elicitation-phase-3