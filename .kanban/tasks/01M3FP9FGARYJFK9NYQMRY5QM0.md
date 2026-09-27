---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fpaqpq5pxb6r5x30q7v5ac
  text: 'Correction: there are 4 tool-hosting tasks, not 5: 01M3FP9700G1GWA15B0GEZQGMD (1), 01M3FP9FGARYJFK9NYQMRY5QM0 (2), 01M3FP9WTFQEQZ8Q4YJDXRA4D9 (3), 01M3FPA83C04HNESZYBEBTPRDG (4).'
  timestamp: 2026-09-26T20:25:57.719151+00:00
- actor: claude-code
  id: 01m3g44a1vqv46hgr5fm0vjqg6
  text: |-
    Research:
    - The 6 router files use only each other, RunKind, OperationOutcome, ToolResultAppendBoundary, ToolResultAppend and ULID. All of these are in Extras. The router extensions `ULID.stringLength`, `ULID.generate()` and `ULID(_:)` are not in Extras. Extras uses `ULID()` and `ULID(ulidString:)`.
    - All tests in the router SubmissionBoundaryToolTests and SubmissionBoundaryToolPublicSurfaceTests need a RoutedSession. The router public-surface target has SubmissionBoundaryToolConformancePublicSurfaceTests, which needs no session. That one is copied. A small new test holds the decorator forwarding.
    - ToolFailureDeliveryTests: the last 2 tests need ToolMounting (task 3). They are not copied.
    - ElicitationEnvelopeTests: the 2 renderedLine tests need the router type OperationEventSegment. They are not copied. The other tests test Elicitation.swift, which is already in Extras.
    - PendingRunEnvelope.replacing(detail:) has one caller: the router TokenCappingTool (router Session/, not in this move). No test calls it. Per the user direction (simple, keep only what the tests need), it is not copied. Task 4 must add it back if the router capping layer uses the Extras envelope.
  timestamp: 2026-09-27T00:27:07.195172+00:00
- actor: claude-code
  id: 01m3g4fxnxm5yfz18gtjvvq5e1
  text: |-
    Implementation landed (user direction: keep the behavior, write each file as simply as possible).
    Line counts, router -> Extras:
    - SubmissionBoundaryTool 24 -> 15
    - ToolDecorator 39 -> 20
    - ToolFailureDelivery 191 -> 162
    - PendingRunEnvelope 238 -> 154
    - ToolMount 49 -> 51
    - BackgroundTool 100 -> 92
    - Total 641 -> 494
    Simplifications (same behavior, the copied tests prove it):
    - PendingRunEnvelope: one pending init with `next: String? = nil` in place of two inits. `rendered` builds a list of fields. `decoded(fromRendered:)` decodes, checks the ULID and the pending fields, and compares with `rendered`. The prefix/infix/suffix constants and the prefix scan are gone, because the compare with `rendered` already holds the exact frame. The token is now JSON-escaped like the other fields (no change for a ULID). `replacing(detail:)` is not copied (see the research comment).
    - ULID: `ULID()` and `ULID(ulidString:)`. No ULID extension was added.
    - ToolFailureDelivery, ToolDecorator, SubmissionBoundaryTool, BackgroundTool, ToolMount: the same code, with short doc comments. The comment that tells why a failure must not throw (the session cancels the round) and why a cancellation still throws is kept.
    Tests (Tests/FoundationModelsExtrasTests):
    - Hosting/PendingRunEnvelopeTests.swift: all 9 router tests. A local DecodedEnvelope replaces MountFixtures.
    - Hosting/ToolFailureDeliveryTests.swift: 11 of 13 router tests, with small local fixtures. The 2 ToolMounting tests wait for task 3.
    - Hosting/SubmissionBoundaryToolPublicSurfaceTests.swift: copy of the router SubmissionBoundaryToolConformancePublicSurfaceTests (plain import).
    - Hosting/SubmissionBoundaryToolTests.swift: new, a chain of 2 decorators passes each boundary to the conformer. The router session tests need a RoutedSession.
    - Hosting/BackgroundToolPublicSurfaceTests.swift: new, plain import: the BackgroundTool defaults, ToolMount.synchronous, a background mount, the ToolMountError text.
    - ElicitationEnvelopeTests.swift: all router tests except the 2 renderedLine tests (router OperationEventSegment).
    Red was seen first: the test target did not compile (types missing).
  timestamp: 2026-09-27T00:33:27.741236+00:00
- actor: claude-code
  id: 01m3g4g0zaaestayfc0hz9bwyt
  text: |-
    ### implement — changed
    - evidence: 12 new files. Sources/FoundationModelsExtras/Hosting/{SubmissionBoundaryTool,ToolDecorator,ToolFailureDelivery,PendingRunEnvelope,ToolMount,BackgroundTool}.swift (494 lines, router 641). Tests/FoundationModelsExtrasTests/Hosting/{PendingRunEnvelopeTests,ToolFailureDeliveryTests,SubmissionBoundaryToolTests,SubmissionBoundaryToolPublicSurfaceTests,BackgroundToolPublicSurfaceTests}.swift and Tests/FoundationModelsExtrasTests/ElicitationEnvelopeTests.swift. `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: all pass (main run 587 tests in 53 suites; the 6 new suites: 44 tests pass). Router not changed. Not committed.
    - next: /review
  timestamp: 2026-09-27T00:33:31.114601+00:00
depends_on:
- 01M3FP9700G1GWA15B0GEZQGMD
position_column: doing
position_ordinal: '80'
title: 'Tool hosting 2: move the leaf tools (SubmissionBoundaryTool, ToolDecorator, ToolFailureDelivery, PendingRunEnvelope, ToolMount, BackgroundTool)'
---
## Why
Second of 5 tool-hosting tasks (decision 2026-09-26: the router `Hosting/` folder moves into the core `FoundationModelsExtras` target; no new product or target). This task moves the hosting files that do not depend on the run-plane actor or on `ToolContext`.

## What to do
Source: `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Hosting/`. Destination: `Sources/FoundationModelsExtras/Hosting/`.
1. Copy these files (641 lines):
   - `SubmissionBoundaryTool.swift` (24).
   - `ToolDecorator.swift` (39).
   - `ToolFailureDelivery.swift` (191).
   - `PendingRunEnvelope.swift` (238).
   - `ToolMount.swift` (49).
   - `BackgroundTool.swift` (100).
   A check of the code (not the comments) shows that these files use only each other, `RunKind`, and the types of task 01M3FP9700G1GWA15B0GEZQGMD. If a file needs a type that is not yet in Extras, stop and record it on the task.
2. Make `SubmissionBoundaryTool`, `ToolMount` and `BackgroundTool` public. The multitool uses them.
3. Change doc comments that name `RoutedSession`, `SessionEvent` or `SessionOutbox` to general words.
4. Keep each comment that tells why a construct is necessary. Do not simplify the cancellation code.
5. Copy the router tests of these types into `FoundationModelsExtrasTests`: `SubmissionBoundaryToolTests`, `SubmissionBoundaryToolPublicSurfaceTests`, `ToolFailureDeliveryTests`, `PendingRunEnvelopeTests`, and the parts of `ElicitationEnvelopeTests` that do not need a `RoutedSession`. Do not change the router tests.

## Acceptance criteria
- [x] The 6 files are in `Sources/FoundationModelsExtras/Hosting/`.
- [x] `SubmissionBoundaryTool`, `ToolMount` and `BackgroundTool` are public, with doc comments.
- [x] No doc comment names a router type.
- [x] The copied tests pass. `swift build` and `swift test` pass.

#tool-hosting #cross-repo