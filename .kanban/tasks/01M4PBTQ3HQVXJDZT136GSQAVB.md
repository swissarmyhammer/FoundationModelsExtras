---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
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