---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ghjs0p4pvs74mqhpr9w6y9
  text: |-
    Research done.
    - Two sinks in Sources forward events: `RunEventFunnel` (ToolRun.swift), which is the sink of each ToolContext of a String run, and `MountedRunUpstreamSink` (ToolContext.swift), which stamps again under the outer token. Both must forward `post(display:)`. `ContextBindingTool` gives the site sink direct to its context, so it needs no change.
    - In this package, the model input lane is `post(event:)` (the host stages those events) and `RunPlane.updateProgress` (the progress detail of a background run). A display event must use neither.
    - Plan: `ToolDisplayEvent` and `ToolDisplayContent` in OperationEvents/. They are `Sendable` and `Equatable`, and not `Codable`, so a host cannot record them with the events of the journal by accident. `ToolContext.post(display:)` takes a `ToolDisplayEvent.Kind` and stamps tool, op and token. The funnel sends a display event upstream in the same order chain as the other events, with no change to the timeout state (task ^jt7qx6k decides the timeout).
    - The follow-up task ^jt7qx6k adds `emit(chunk:)` and `update(title:kind:locations:)` on top of `post(display:)`.
  timestamp: 2026-10-09T14:37:54.582034+00:00
- actor: claude-code
  id: 01m4gjb9v1dyjy434sqk7g218d
  text: |-
    Implementation landed.
    - New `Sources/FoundationModelsExtras/OperationEvents/ToolDisplayEvent.swift`: `ToolDisplayContent` (`.text`, `.diff(path:oldText:newText:)`, `.json`) and `ToolDisplayEvent` (`tool`, `op`, `correlationID`, `kind`: `.contentChunk`, `.contentReplace`, `.metadata(title:kind:locations:rawInput:)`), with `ToolDisplayEvent.ToolKind` (ACP tool kinds) and `ToolDisplayEvent.Location`. Not `Codable`, so a host cannot journal it by accident.
    - `OperationEventSink.post(display:)` with a no-op default.
    - `ToolContext.post(display:)` takes a `ToolDisplayEvent.Kind` and stamps tool, op and completion token.
    - `RunEventFunnel.post(display:)` sends the event upstream on the same order chain. No timeout reset, no `hasDeliveredAnyEvent`, no `updateProgress`. The private `enqueue` now takes a delivery closure, so events and display events share one path.
    - `MountedRunUpstreamSink.post(display:)` stamps again under the outer run.
    - Discovery: `BackgroundToolRunner` posts the pending envelope as a progress event BEFORE `runPlane.start`, so a test of a background run sees one `.progress` event in the sink and `latestProgressDetail == nil` on the run plane.
    - The SwiftPM line "warning: missing creator for mutated node: (...mlx-swift_Cmlx.bundle/Contents/MacOS)" comes from the build system for the mlx bundle, not from the source. It is not from this change.
    - Timeout sign of life and grace-period withdraw stay for ^jt7qx6k, as that card says.
  timestamp: 2026-10-09T14:51:18.241298+00:00
- actor: claude-code
  id: 01m4gjbe8sjyz8k1np4wae8fay
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsExtras/OperationEvents/ToolDisplayEvent.swift (new), Sources/FoundationModelsExtras/OperationEvents/OperationEventSink.swift, Sources/FoundationModelsExtras/Hosting/ToolContext.swift, Sources/FoundationModelsExtras/Hosting/ToolRun.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolDisplayEventTests.swift (new), Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolContextMountTests.swift, CHANGELOG.md, README.md. `swift test`: 907 tests in 86 suites passed (11 known issues from before this change), 0 failures, no compiler warnings from the source.
    - next: /review
  timestamp: 2026-10-09T14:51:22.777519+00:00
- actor: claude-code
  id: 01m4gjjxb2n24szz8a01pft4q5
  text: |-
    ### test — green
    - evidence: swift test — 907 tests in 86 suites passed, 0 failed, 0 skipped. 11 known issues come from withKnownIssue tests of the telemetry checker (TelemetryCaptureTests), by design. The one build warning is "missing creator for mutated node" for the mlx-swift_Cmlx.bundle. It comes from build tooling, not from source.
    - next: review
  timestamp: 2026-10-09T14:55:27.586347+00:00
- actor: claude-code
  id: 01m4gjkd64njsfr7wv5xce66zs
  text: |-
    ### commit — changed
    - evidence: local commit "feat(hosting): add a display-only event lane for tools" (sha is in the commit log; this comment ships in the same commit)
    - next: review
  timestamp: 2026-10-09T14:55:43.812197+00:00
- actor: claude-code
  id: 01m4gk0jeme0jhjt6e7h39rzjc
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 23974f0). 0 findings, 0 confirmed, 2 refuted. 7 files attempted, 0 failed. The engine did not review CHANGELOG.md and README.md (no validator matches) or the 4 .kanban files (.reviewignore).
    - next: none. The task is in done.
  timestamp: 2026-10-09T15:02:55.188256+00:00
- actor: claude-code
  id: 01m4gk0s736xwyyx3ey7kczj97
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 files
    - test: green — swift test, 907 passed, 0 failed
    - commit: 23974f0
    - review: clean — 0 findings
  timestamp: 2026-10-09T15:03:02.115391+00:00
position_column: done
position_ordinal: e380
title: Add a display-only event lane for tools
---
## Problem

ACP v2 lets an agent send tool output to the client with `tool_call_content_chunk`. It lets an agent set tool-call metadata with `tool_call_update`. FoundationModelsACPAgent changes Router `SessionEvent`s into ACP updates.

Now a tool can only call `ToolContext.progress(_:plan:)`. This is not a usable display stream:
- A new progress event replaces the earlier progress event.
- `SessionOutbox` combines progress events (Router `SessionOutbox.swift:171-180, 248-280`).
- The progress `detail` goes into the model input.

Terminals are out of scope. Do not add terminal support.

## Work

1. Add `ToolDisplayEvent`. It has these fields:
   - `tool`
   - `op`
   - `correlationID`. This is the completion token. Stamp it the same as the other events (see `Hosting/ToolContext.swift:370-381`).
   - `kind`, with these cases:
     - `.contentChunk(ToolDisplayContent)`
     - `.contentReplace([ToolDisplayContent])`
     - `.metadata(title:kind:locations:rawInput:)`
2. Add `ToolDisplayContent`. It holds text, a diff, or JSON.
3. Add `OperationEventSink.post(display:)`. Give it a default implementation that does nothing, the same as `post(invocation:)` (`OperationEvents/OperationEventSink.swift:3-12`).
4. Display events must not go into the model input.
5. Display events must not be combined.
6. Display events must not be recorded in the journal.
7. Nested `ToolContext.mount(_:op:as:)` must send the inner display events again under the outer token (see `ToolContext.swift:289-305, 409-432`).

## Tests

- A display event gets to the sink with the correct token.
- A nested mount stamps the display event again with the outer token.
- No display event is staged for the model.

## Related

- A FoundationModelsRouter task depends on this task. The Router will forward these events.