---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4y24amjpxe2xr6cwj33kqne
  text: |-
    A person asked to start this task. Research and implementation are done.

    What changed:
    - `ElicitationResponse` (Sources/FoundationModelsExtras/OperationEvents/Elicitation.swift) has a new `public let reason: String?`. New factories: `.decline(reason:)` and `.cancel(reason:)`. The old `.decline` and `.cancel` static values stay, with no reason, so sibling call sites compile with no change. The private init keeps the rules: content only on accept, reason only on decline and cancel. Codable: the wire key is `reason` (encodeIfPresent). Decode of a reason with an accept throws, the same as content with a decline.
    - `RunPlane.respond(elicitationId:_:)` already gives the answer to the run unchanged, so the reason of the host goes through for form and URL elicitations. Doc comments now say this.
    - `RunPlane.awaitAnswer`: a second question with the id of an open question now gets `.cancel(reason: RunPlane.duplicateElicitationIdReason)`, not a bare cancel.
    - `ToolContext.elicit` doc comment and README tool-hosting bullets describe the `{ action, content, reason }` shape.

    Not in this task: `RunPlane.sweep` still cancels with no reason, and `cancel(completionToken:)` does not end the questions of the run. Both belong to ^9wbt2dh (reason "run cancelled"). No user (Extras task 18) is also not in this task.

    Sibling packages: no break. Every change is additive. The Router `SessionMessage` text and the Multitool `renderElicitationResponse` do not show the reason yet; other cards own that work.

    Build note: `.build/checkouts/swift-distributed-tracing` held a stale checkout that SwiftPM could not remove ("Operation not permitted"). I moved it to the session scratchpad, and SwiftPM checked it out again.
  timestamp: 2026-10-14T20:37:14.514591+00:00
- actor: claude-code
  id: 01m4y24f6vv3akxc8gfknmgj19
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/OperationEvents/Elicitation.swift, Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift, Sources/FoundationModelsExtras/Hosting/ToolContext.swift, README.md, Tests/FoundationModelsExtrasTests/ElicitationEnvelopeTests.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift. RED: build of the tests failed because `decline(reason:)`, `cancel(reason:)` and `RunPlane.duplicateElicitationIdReason` did not exist. GREEN: `swift test --filter "ElicitationEnvelopeTests|RunPlaneActorTests|ToolContextTests"` 96 tests in 3 suites passed. Full `swift test`: 1150 tests in 106 suites passed, 0 failures.
    - next: /review
  timestamp: 2026-10-14T20:37:19.195975+00:00
position_column: doing
position_ordinal: '80'
title: Carry a reason in elicitation decline and cancel
---
Source: elicitation-plan.md, Extras task 16.

Add a reason to the decline and cancel results of an elicitation. All forms and helpers return `{ action, content, reason }`, with `action` = `accept` | `decline` | `cancel`. `content` is `null` for decline and cancel.

An answer never throws. No user, no relay and run cancel are not errors. They resolve with `cancel` and a reason. A malformed request is a programming error and still throws (`malformedElicitationRequest`, `undecodableElicitationRequest`).

Extras task 17 depends on this task. A Router card (a public SessionEvent `elicitationEnded`) depends on this task. Together they fix ACPAgent gap ^crjmk34.

Do not start this task until a person asks.

- [x] Add a reason to elicitation decline and cancel.
- [x] Send the reason through each path that ends a question with decline or cancel.
- [x] Add tests for the reason on decline and on cancel. #elicitation-phase-1