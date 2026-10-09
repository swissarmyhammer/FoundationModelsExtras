---
assignees:
- claude-code
depends_on:
- 01M4GH3SXGTK24GQS301VHFTW2
position_column: todo
position_ordinal: '8180'
title: Add emit(chunk:) and update(title:kind:locations:) on ToolContext
---
## Problem

Task ^1vhftw2 adds `ToolDisplayEvent` and `OperationEventSink.post(display:)`. A tool must have a simple API on `ToolContext` to send these events.

Terminals are out of scope. Do not add terminal support.

## Work

1. Add `ToolContext.emit(chunk:)`. It sends a `ToolDisplayEvent` with kind `.contentChunk`.
2. Add `ToolContext.update(title:kind:locations:)`. It sends a `ToolDisplayEvent` with kind `.metadata`.
3. Both methods must work in all of these paths (`Hosting/ToolMounting.swift:194-251`):
   - `ContextBindingTool`
   - `BackgroundToolRunner`
   - `RunToCompletionRunner`
4. Both methods must work in a background run after the grace period (`BackgroundToolRunner.swift:94-134`).
5. Decide if display events that are staged in the grace period are withdrawn the same as progress events. Document the decision.
6. A display event must count as a sign of life for the run timeout, the same as progress (`ToolContext.swift:198-202`, `ToolRun.swift:129-139`). If you decide that it must not count, document the reason.

## Tests

- Add a test for each runner path: `ContextBindingTool`, `BackgroundToolRunner` and `RunToCompletionRunner`.
- Add a test for a background run after the grace period.
- Add a test for the grace-period decision (withdrawn or not withdrawn).
- Add a test that a display event resets the run timeout, or a test for the documented behavior.

## Related

- Depends on ^1vhftw2 (Add a display-only event lane for tools).