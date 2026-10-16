---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51z2fw5a3a2dppd9ym524te
  text: |-
    ### review — clean
    - evidence: review sha 4820dfa..ae2f753; 5 files reviewed; 7 validators attempted, 0 failed; findings 0, confirmed 0, refuted 0. No findings.
    - next: none. The task is in done.
  timestamp: 2026-10-16T09:00:46.341453+00:00
- actor: claude-code
  id: 01m51z30x6x0v840dtt28p2vq4
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — RunPlaneActor.swift, ToolContext.swift, ToolRun.swift, OperationEventSink.swift, ElicitationEndEventTests.swift (7 new tests, one is an exit test of the precondition)
    - test: green — swift test, 1191 tests in 114 suites passed (one full run for E1 and E2 together)
    - commit: ae2f753
    - review: clean — no findings
  timestamp: 2026-10-16T09:01:03.782003+00:00
position_column: done
position_ordinal: ff9a80
title: 'E2: The run plane ends one open question with a given response'
---
## What

Add `public func endElicitation(_ elicitationId: ULID, with response: ElicitationResponse) async -> Bool` to `RunPlane` (`Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift`). A parent session uses it to end its copy of a relayed question when the question ends in the child.

- It uses the same end path as the cancels of the run plane, but with `response` in place of the fixed cancel with `runCancelledReason`:
  - In one step with no suspension, the question leaves `openElicitations()` and goes into `endingElicitations()`.
  - The sink gets `post(elicitationEnded:response:)` after the post of the question returned.
  - The run resumes with `response` only after the end post returned.
- It gives `true` only when a question with that id was open. An unknown id, an answered question, a question whose completion post is in progress, and a question that a different end took give `false`, with no end post. A second call for the same id gives `false`.
- An accepted URL question that waits for its completion is still open, so this call ends it.
- An accept in `response` is a programmer error (`precondition`).
- The same rule as for the other cancels: a sink must not await this call inside a post.
- No new `OperationEventSink` method. This is an additive change.

## Acceptance Criteria

- [x] An end of an open form question gives `true`. The end post has the given response, it comes after the question post, and the run gets the response after the end post.
- [x] An end of an accepted URL question gives `true`, and the run gets the given response.
- [x] An end of an unknown id gives `false` and posts nothing.
- [x] A second end of the same id gives `false` and posts no second end.
- [x] An end after an answer gives `false` and posts no end.
- [x] An end while the completion post is in progress gives `false`.

## Tests

Fixed-order Swift Testing tests in `Tests/FoundationModelsExtrasTests`. No clock, sleep, poll, retry or time limit.

#elicitation-phase-4