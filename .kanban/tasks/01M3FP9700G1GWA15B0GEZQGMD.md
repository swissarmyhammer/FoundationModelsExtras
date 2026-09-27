---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fpap5x03qrw9w0wx5gv7q1
  text: 'Correction: there are 4 tool-hosting tasks, not 5: 01M3FP9700G1GWA15B0GEZQGMD (1), 01M3FP9FGARYJFK9NYQMRY5QM0 (2), 01M3FP9WTFQEQZ8Q4YJDXRA4D9 (3), 01M3FPA83C04HNESZYBEBTPRDG (4).'
  timestamp: 2026-09-26T20:25:56.157629+00:00
- actor: claude-code
  id: 01m3fpbaw343tdsdxwpgxgjmk5
  text: 'Added requirement: task 01M3FN8WD0G0NJ7QAAKSPZ9RW1 did not copy `Concurrency/SerialAsyncChain.swift` or `Concurrency/CancellableWait.swift`, because no work-queue file uses them. The hosting code uses `SerialAsyncChain`. Copy `SerialAsyncChain.swift` (and `CancellableWait.swift` if a hosting file uses it) in this task, with its router tests, into `Sources/FoundationModelsExtras/ModelPool/`. `ModelCallMark` and `RaceGate` are already in Extras.'
  timestamp: 2026-09-26T20:26:17.347166+00:00
- actor: claude-code
  id: 01m3g32qv39f39gvhg76p1q0ap
  text: |-
    Research:
    - `ToolCallSpan` in the router uses `RouterTracing` (267 lines). Extras keeps only the four names that the tool span uses (span name "FoundationModelsRouter.tool", keys "tool.name", "session.id", "tool.run_kind", "tool.outcome") inside `ToolCallSpan`, with the same string values, so traces do not change.
    - `ToolResultAppendBoundary` in the router holds a `RoutedSessionActor`. In Extras it holds a `@Sendable (ToolResultAppend) async -> Void` closure. The router binds it with `{ await self.noteToolResult($0) }`.
    - `OperationEventSink` and `ToolInvocationRecord` are already in Extras, so `ToolCallReport.init?(closing:attachments:)` and `OperationEventSink.postToolCallReport(closing:attachments:)` move with the seams.
    - `CancellableWait` is used only by `LiveModelLoader` (not a hosting file), so it does not move.
    - `LostRunErrorTests` and `DeclaredRunKindTests` need `RunToCompletionRunner`, `BackgroundToolRunner`, `BackgroundTool`, `ToolContext` and `SessionMailbox`. These move in tasks 2 and 3, so these tests cannot compile in this task. `ToolTracingTests` and `SpanContentSafetyTests` need a `RoutedSession`. The router tests that need neither are the three `postToolCallReport` tests in `ToolInvocationLivenessTests`.
  timestamp: 2026-09-27T00:08:47.203250+00:00
- actor: claude-code
  id: 01m3g3gab0wgcpascgwwmct7p8
  text: |-
    ### implement — changed
    - evidence: Package.swift (swift-distributed-tracing from 1.4.1; `Tracing` on the core target only; `InMemoryTracing` on FoundationModelsExtrasTests), plan.md §5, Tests/MarketplaceTests/PackageLayoutTests.swift (tracing guard, 6 new cases). New sources (router -> Extras lines): Hosting/ToolCallSpan.swift 59 -> 74 (holds its 4 names, no RouterTracing), Hosting/ToolResultAppendBoundary.swift 98 -> 88 (boundary is a struct with a `receive` closure), Hosting/RunPlane.swift 57 -> 62, Hosting/LostRunError.swift 2 -> 4, Hosting/ElicitationDelivery.swift 21 -> 21, Hosting/ToolCallAttachment.swift 26 -> 23, Hosting/ToolCallReport.swift 58 (router: struct 52 in SessionEvent.swift + `init?(closing:)` 21 in OperationEventJournal.swift), Hosting/HostingSeams.swift 51 (router: 3 protocols + `postToolCallReport` extension, about 84 lines over 2 files), ModelPool/SerialAsyncChain.swift 22 -> 26 (public). New tests: Hosting/ToolCallSpanTests (3), Hosting/ToolResultAppendTests (6), Hosting/ToolCallReportTests (5, 3 copied from router ToolInvocationLivenessTests), ModelPool/SerialAsyncChainTests (2; a mutation that removes the wait on the earlier delivery makes the FIFO test fail). `swift build` 0 warnings; `swift test` 1168 tests passed, 0 failed (125+34+44+26+396+543 over 6 bundles). CancellableWait not copied: no hosting file uses it.
    - gap moved: `LostRunErrorTests` and `DeclaredRunKindTests` need the runners and `ToolContext`; recorded as a requirement on ^dxra4d9.
    - next: /review
  timestamp: 2026-09-27T00:16:12.128931+00:00
depends_on:
- 01M3FN8WD0G0NJ7QAAKSPZ9RW1
- 01M3FN9KTQA9S37VTZXMMSRS07
position_column: doing
position_ordinal: '80'
title: 'Tool hosting 1: add swift-distributed-tracing, ToolCallSpan, the run value types and the seam protocols'
---
## Why
Decision (user, 2026-09-26): an interface in Extras with its implementation in the router is messy, so one package owns both. The complete tool-hosting code (`FoundationModelsRouter/Sources/FoundationModelsRouter/Hosting/`) moves into the core `FoundationModelsExtras` target. Then the multitool can use tool hosting with no dependency on the router. No new product or target.

This is the first of 5 tasks. It moves the leaf types that the other hosting files use.

## What to do
Source root: `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/`. Destination: `Sources/FoundationModelsExtras/Hosting/`.
1. Add `.package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1")` to `Package.swift` (the same pin as the router), and the `Tracing` product to the core target only. Record it in `plan.md` §5 as a dependency that fought its way in: the tool spans move with the hosting code.
2. Copy these files (about 360 lines):
   - `Tracing/ToolCallSpan.swift` (59).
   - `Session/ToolResultAppendBoundary.swift` (98): `ToolResultAppend`, `ToolResultAppendBoundary`.
   - `Hosting/RunPlane.swift` (57): `RunKind`, `BackgroundRun`, `WaitOutcome`, `CancelOutcome`.
   - `Hosting/LostRunError.swift`, `Hosting/ElicitationDelivery.swift`, `Hosting/ToolCallAttachment.swift`.
   - `ToolCallReport` (public struct, `Session/SessionEvent.swift:179`).
   - The seam protocols `ToolCallReportSink` (`Session/OperationEventJournal.swift:75`), `BackgroundRunSettlementObserver` (`Session/OperationEventJournal.swift:146`) and `StagedEventWithdrawing` (`Session/SessionOutbox.swift:42`). Put them in one file, `Hosting/HostingSeams.swift`. The router keeps its conformances.
3. Make the types public where the router or the multitool uses them.
4. Doc comments that name `RoutedSession`, `SessionEvent` or `SessionOutbox`: change them to general words (for example "the host session", "the session outbox").
5. Keep each comment that tells why a construct is necessary.
6. Copy the router tests of these types into `FoundationModelsExtrasTests` (for example `LostRunErrorTests`, `DeclaredRunKindTests`, and the `ToolCallSpan` parts of `SpanContentSafetyTests` that do not need a `RoutedSession`). Do not change the router tests.

## Acceptance criteria
- [ ] `Package.swift` has swift-distributed-tracing `from: "1.4.1"` on the core target only.
- [ ] `plan.md` §5 records the tracing dependency and the reason.
- [ ] No doc comment names a router type.
- [ ] The copied tests pass. `swift build` and `swift test` pass.

## Note on names
The router has public types with the same names. When the router pins an Extras commit that has these types, the router must remove its own copies in the same change. The router session makes that task.

#tool-hosting #cross-repo