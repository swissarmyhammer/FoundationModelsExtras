---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4pb79137s36jv8m4dtjvvbb
  text: |-
    Research done.
    - The default text is only in PendingRunEnvelope.defaultCollectInstruction(forCompletionToken:). BackgroundTool.collectInstruction default calls it. BackgroundToolRunner passes the tool sentence into the envelope.
    - Callers that compare with the default: BackgroundToolPublicSurfaceTests, BackgroundToolRunnerTests, ToolHostingPublicSurfaceTests. They compare with the function, not with a literal, so they stay correct.
    - README example and its mirror ToolHostingReadmeTests have a model-facing Wait tool. RunPlane.wait(completionToken:seconds:) is public, so the mirror test can collect the result from the run plane.
    - The nested IntegrationTests package has its own wait tool and its own collectInstruction text ("Call wait again ..."). The task scope for the search is Sources, Tests, README.md and docs/, so this pass does not change IntegrationTests. I record it as a follow-up task.
    - docs/ has no wait-tool text.
  timestamp: 2026-10-11T20:42:12.899840+00:00
- actor: claude-code
  id: 01m4pbtyw5f62t1ybwwf9f5q7f
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/Hosting/PendingRunEnvelope.swift (public static let pendingWorkInstruction: String, approved text word for word; defaultCollectInstruction = token sentence + " " + pendingWorkInstruction; doc comments), Sources/FoundationModelsExtras/Hosting/BackgroundTool.swift (doc of the default collectInstruction), Tests/FoundationModelsExtrasTests/Hosting/PendingRunEnvelopeTests.swift (exact-text test, composition test, new in-order facts, "wait tool"/"call wait"/"Do not answer yet" added to the forbidden fragments), Tests/FoundationModelsExtrasTests/Hosting/ToolHostingReadmeTests.swift and README.md (model-facing Wait tool removed; the host collects with RunPlane.wait; comments say the session injects the result).
    - RED: swift test --filter PendingRunEnvelopeTests failed to compile, "type 'PendingRunEnvelope' has no member 'pendingWorkInstruction'". GREEN: 11/11 passed.
    - Full swift test: 964 tests in 90 suites passed (11 known issues that existed before). The only build warning is the toolchain "missing creator for mutated node" warning for the mlx-swift bundle, which is not from this change.
    - A separate swift build failed one time in Sources/FoundationModelsExtras/ModelPool/Mailbox.swift. A concurrent agent edits that file for task ^dxrdq5. This task does not touch it. The swift test build after it compiled.
    - Search: rg for "wait tool", "call wait", "Do not answer yet" in Sources, Tests, README.md, docs finds only the forbidden-fragment list.
    - Out of scope: IntegrationTests still has a wait tool and "Call wait again" text. Follow-up task ^6gsqavb.
    - The three callers that compare with defaultCollectInstruction (BackgroundToolPublicSurfaceTests, BackgroundToolRunnerTests, ToolHostingPublicSurfaceTests) passed in the full run.
    - next: /review
  timestamp: 2026-10-11T20:52:57.861105+00:00
- actor: claude-code
  id: 01m4pbv422f2bdxecythd28e4r
  text: 'Correction to the step record: the concurrent Mailbox task is ^a0xrdq5 (01M4NXXETD1P6X4V8RMA0XRDQ5), not ^dxrdq5.'
  timestamp: 2026-10-11T20:53:03.170770+00:00
position_column: doing
position_ordinal: '80'
title: Replace the wait-tool text in PendingRunEnvelope with PendingRunEnvelope.pendingWorkInstruction
---
## Why

The pending-work text is in two other packages that must stay the same as Extras:
- FoundationModelsMultitool `PendingWorkInstruction.text` (commit dd32c9e, `Sources/FoundationModelsMultitool/Invocation/PendingWorkInstruction.swift`).
- FoundationModelsAgents `AgentsToolText.injectionSentences`.

The user decided that Extras owns the one text, because Extras defines `BackgroundTool`, `PendingRunEnvelope` and `collectInstruction`. Multitool and Agents will use `PendingRunEnvelope.pendingWorkInstruction` by this exact name.

The current text in `PendingRunEnvelope.defaultCollectInstruction(forCompletionToken:)` (`Sources/FoundationModelsExtras/Hosting/PendingRunEnvelope.swift:37`) says "Do not answer yet ... call the wait tool ... call wait again". There is no wait tool. A SWE-bench run (no-otel-1011) showed that this type of text makes the model loop (73 no-op tool calls).

## What to do

1. Add `public static let pendingWorkInstruction: String` on `PendingRunEnvelope`. Use this text word for word (the user approved it):

   "This is not the result. When the work finishes, the session injects its result into this conversation as a new message. That message starts you working again, so you do not need to wait, to check, or to ask for it. Do not call a tool to wait or to check. If you have other work that does not need this result, do that work now. If no other work can be done until the result comes back, do nothing: write no text and call no tool. When the injected result arrives, continue the task from it."

2. Change `defaultCollectInstruction(forCompletionToken:)` to return one sentence that names the run by its completion token, then one space, then `pendingWorkInstruction`:
   `"This run continues in the background, with completion token \"<token>\". " + pendingWorkInstruction`.
   Remove all "wait tool" text.

3. Update the doc comments (`PendingRunEnvelope.swift`, `BackgroundTool.swift:77`).

4. Update the tests:
   - `Tests/FoundationModelsExtrasTests/Hosting/PendingRunEnvelopeTests.swift:69-100`: the test must expect the new text. Add a test that `pendingWorkInstruction` is the exact approved text, and that the default sentence is the token sentence + " " + `pendingWorkInstruction`. Add "wait tool", "call wait", "Do not answer yet" to the forbidden fragments.
   - `BackgroundToolPublicSurfaceTests.swift:46`, `BackgroundToolRunnerTests.swift:319`, `ToolHostingPublicSurfaceTests.swift:375` compare with `defaultCollectInstruction`; make sure they still pass.

5. README: the background tool example (`README.md:899-956`) gives the model a `Wait` tool, and the comment says "the model collects the result later". This contradicts the new text. Remove the model-facing `Wait` tool from the example and change the comment to say that the session injects the result. Keep the `ToolContext.wait(completionToken:seconds:)` API; it is a host API. Update the mirror test `readmeBackgroundToolExample` in `Tests/FoundationModelsExtrasTests/Hosting/ToolHostingReadmeTests.swift` to match (it may collect the result with the run plane or `ToolContext` directly, not with a model tool).

6. Search Sources, Tests, README.md and docs/ again for "wait tool", "call wait", "Do not answer yet". No such text must remain, except in the forbidden-fragment list of the tests.

## Acceptance criteria

- `PendingRunEnvelope.pendingWorkInstruction` exists, is public, and equals the approved text exactly.
- `defaultCollectInstruction(forCompletionToken:)` == `"This run continues in the background, with completion token \"\(token)\". " + pendingWorkInstruction`.
- No "wait tool", "call wait" or "Do not answer yet" text in the package (other than forbidden-fragment test data).
- `swift build` and `swift test` pass with no warnings.