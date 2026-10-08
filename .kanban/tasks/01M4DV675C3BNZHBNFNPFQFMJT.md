---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4dv7v534cb22dhq5j6d72v9
  text: 'Research: In Sources, three places make an OperationEvent: ToolContext.stamped(...) (used by post, progress, message, elicit), ToolRun terminal event (.completed), and RunPlaneActor sweep (.completed). Only stamped/post rebuild an event from another event. The two .completed builders never carry a plan (plan is for .progress only). MountedRunUpstreamSink sends non-completed events through context.post, so it keeps plan when post keeps it. The journal and restore code are not in this package (Router). OperationEvent uses the synthesized Codable, which decodes an Optional with decodeIfPresent, so a record with no plan key decodes with plan == nil.'
  timestamp: 2026-10-08T13:28:58.787402+00:00
- actor: claude-code
  id: 01m4dvqmb6f23e5bhn19p7jftz
  text: |-
    Implementation landed (TDD). RED: `swift build --build-tests` failed with "cannot find type 'PlanSnapshot' in scope". GREEN: `swift test --filter 'PlanSnapshotTests|ToolContextTests'` passed 32 tests in 2 suites. Full `swift test` passed 887 tests in 85 suites. The 11 known issues are withKnownIssue cases that existed before. The one warning is SwiftPM "missing creator for mutated node" on the mlx-swift_Cmlx bundle. It was there before and does not come from this code.

    Changes:
    - New Sources/FoundationModelsExtras/OperationEvents/PlanSnapshot.swift: PlanSnapshot (id, entries), Entry, Priority, Status (inProgress = "in_progress").
    - OperationEvent.plan, with `plan: PlanSnapshot? = nil` as the last init parameter. The synthesized Codable decodes a missing key as nil.
    - ToolContext.progress(_:plan:), stamped(...plan:), post(_:) keeps event.plan, and the doc comments are updated.
    - README.md and CHANGELOG.md are updated, the same as the commit for the .message kind.

    Item 4 (other field-by-field rebuilds): I found no other place to change. ToolRun's terminal event and the RunPlaneActor sweep build new .completed events, which carry no plan by contract. MountedRunUpstreamSink sends each event that is not .completed through context.post, which now keeps plan. It turns a .completed event into progress(event.detail), and a .completed event carries no plan. The journal and restore code are in Router, not in this package.
  timestamp: 2026-10-08T13:37:36.102101+00:00
- actor: claude-code
  id: 01m4dvqps220prabh8kkt6f9xm
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/OperationEvents/PlanSnapshot.swift (new), Sources/FoundationModelsExtras/OperationEvents/OperationEvent.swift, Sources/FoundationModelsExtras/Hosting/ToolContext.swift, Tests/FoundationModelsExtrasTests/PlanSnapshotTests.swift (new), Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift, README.md, CHANGELOG.md. `swift test`: 887 tests in 85 suites passed.
    - next: review
  timestamp: 2026-10-08T13:37:38.594812+00:00
- actor: claude-code
  id: 01m4dvv9xmrdgaph5rdc9nvb2w
  text: |-
    ### test - green
    - evidence: swift test - 887 tests in 85 suites passed, 0 failed, 11 known issues (the withKnownIssue cases that existed before, in TelemetryCaptureTests). No skipped tests. After a touch of the changed files, swift build --build-tests recompiled them with zero compiler warnings. One build-system warning remains: "missing creator for mutated node ... mlx-swift_Cmlx.bundle". It comes from the mlx-swift dependency bundle, not from this package's code.
    - next: review
  timestamp: 2026-10-08T13:39:36.500194+00:00
position_column: doing
position_ordinal: '80'
title: Send an agent plan through ToolContext.progress as a typed PlanSnapshot
---
## Goal

A tool must send a plan (a copy of the ACP v2 agent plan, https://agentclientprotocol.com/protocol/v2/agent-plan) to the host. The plan goes through Router and the ACP agent to the client. It goes one way only. It is a typed field on `OperationEvent`, the same as `elicitation`. The model must never get the plan.

Why not `detail`: Router puts `detail` in the model text at the next submission. A plan in `detail` as JSON uses model context, and the agent cannot reliably identify it.

## Limits

- Extras must not depend on FoundationModelsACP.
- Do not add a new `OperationEventKind`. A plan goes on a `.progress` event.

## Changes

1. Add `PlanSnapshot` in `Sources/FoundationModelsExtras/OperationEvents/` (a new file `PlanSnapshot.swift`, next to `Elicitation.swift`). `Sendable`, `Codable`, `Equatable`. Public memberwise init.
   - `id: String`. A session can have more than one plan. An update replaces the plan that has this id.
   - `entries: [Entry]`. This is always the full list. The client replaces the full plan.
   - `PlanSnapshot.Entry`: `content: String`, `priority: Priority`, `status: Status`.
   - `PlanSnapshot.Priority`: `high`, `medium`, `low` (String raw values).
   - `PlanSnapshot.Status`: `pending`, `inProgress`, `completed`, `cancelled`. Use the raw value `in_progress` for `inProgress`, to agree with ACP.
2. Add `public let plan: PlanSnapshot?` to `OperationEvent` (`OperationEvents/OperationEvent.swift:28`). Add `plan: PlanSnapshot? = nil` as the last parameter of `init`. Document it: non-nil only when `kind == .progress`. A record with no `plan` key must decode as before (the journal and the restore path read old events).
3. In `Hosting/ToolContext.swift`:
   - Change `progress(_:)` (line 153) to `progress(_ detail: String, plan: PlanSnapshot? = nil)`. `detail` stays a short text line for the model, for example "3 of 7 tasks done".
   - Add `plan` to the private `stamped(...)` helper (line 311).
   - Make `post(_:)` (line 146) keep `event.plan`. Update its doc comment (line 142), which now names only kind, detail, outcome and elicitation.
4. Find all other places that copy or rebuild an `OperationEvent` field by field (for example a mounted-call forward path, journal and restore code) and make them keep `plan`. Use `get blastradius` on `OperationEvent.init`.

## Tests

- `PlanSnapshot` encode/decode round trip. `inProgress` encodes as `"in_progress"`.
- An `OperationEvent` JSON with no `plan` key decodes with `plan == nil`.
- `OperationEvent` with a plan does a round trip.
- `ToolContext.progress("3 of 7 tasks done", plan: snapshot)` posts a `.progress` event whose `plan == snapshot` and whose `detail` is the text only.
- `ToolContext.post(_:)` keeps `plan`.
- `progress(_:)` with no plan still posts `plan == nil`.

## Related work

- The Router session (foundationmodelsrouter-1c) makes a task to send `plan` to the host and to keep it out of the model text.
- The FoundationModelsACPAgent session makes a task to send `plan` to the client as an ACP plan update.