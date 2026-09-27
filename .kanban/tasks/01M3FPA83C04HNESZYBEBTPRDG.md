---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3g98z1aw9yk9r4wa017ctfb
  text: |-
    Research (implement start):
    - Router uses outside Hosting/ (Sources/FoundationModelsRouter), which need Extras public API after the router removes Hosting/:
      - RunPlane (router SessionMailbox): init(), makeCompletionToken(), attach(settlementObserver:) (RoutedSessionActorRunJournal), backgroundRuns() (RoutedSessionActorCompaction), settledRunTokens() (RoutedSessionActorPump), respond(elicitationId:_:) and complete(elicitationId:) (RoutedSessionActorQueueing), sweep() (RoutedSessionActorForking).
      - ToolContext: the memberwise init (sessionID:runPlane:sink:tool:op:completionToken:isCancelled:) for the ambient context (RoutedSessionActorAnswerExecution), and $current.withValue.
      - MountSite and ToolMounting.makeWrapped(tool:site:configuration:) (router makeSessionMounted in Session/ToolOutputCapping.swift).
      - ToolFailureDelivery.makeWrapped(tool:) (ToolOutputCapping) and throwingTool(of:) (DiscoveryPriming).
      - ToolDecorator (TokenCappingTool conforms, and gets submissionWillBegin from the extension).
      - PendingRunEnvelope.decoded(fromRendered:), rendered and replacing(detail:) (TokenCappingTool). replacing(detail:) was not copied in task ^mry5qm0; this task adds it back.
    - Multitool uses (sources): ToolContext current, post, progress, elicit, attach, backgroundRuns, wait, cancel, mount, tool, op, completionToken, makeCompletionToken; tests also read sessionID. BackgroundTool, ToolMount, ToolMountError, SubmissionBoundaryTool, LostRunError, BackgroundRun, RunKind are already public. The multitool tests use SessionMailbox.track/updateProgress/wait/sweep through @testable import of the router; those stay internal in Extras (not in the list), so the multitool tests need a change when the multitool moves to Extras.
    - Router tests: ToolContextTests, ToolContextMountTests, ToolContextTokenPublicSurfaceTests and ToolMountingTests need no RoutedSession. ToolContextMountSinkPublicSurfaceTests drives a ScriptedSessionFixture only to get a bound ToolContext; with the public ToolContext init and RunPlane(), the same tests run over a context built directly. MountedRunAttachmentCarrierTests (session event stream), MountedRunSweptTerminalTests (RoutedSession.close()), NestedRunTerminalForwardingTests (RoutedSession journal and stream) and ElicitationRoutingTests (RoutedSession.respond/complete) need a RoutedSession.
    - OperationVocabulary.swift: only public typealiases that re-export Extras names (OperationEvent, ElicitationRequest, ...) under the router module. It uses no router type, but in Extras the names already exist, so a copy has no purpose.
  timestamp: 2026-09-27T01:57:02.634974+00:00
- actor: claude-code
  id: 01m3gaetft5pkxmvyacrn9hzd1
  text: |-
    Implementation landed. Not committed.

    Public members (the multitool list, plus the real uses of the router outside Hosting/; nothing else):
    - ToolContext (struct): current (@TaskLocal), init(sessionID:runPlane:sink:tool:op:completionToken:isCancelled:attachmentSink:) (router ambient context), sessionID, tool, op, completionToken, post(_:), progress(_:), attach(_:), elicit(_:), backgroundRuns(), wait(completionToken:seconds:), cancel(completionToken:), mount(_:op:as:), mount(_:op:as:postingTo:), makeCompletionToken(). Internal: runPlane, isCancelled (the router docs also keep isCancelled internal), init(calling:on:sink:completionToken:state:).
    - RunPlane (actor): init(), makeCompletionToken(), attach(settlementObserver:), backgroundRuns(), settledRunTokens(), respond(elicitationId:_:), complete(elicitationId:), sweep(). Internal: start, updateProgress, wait, cancel, waiterCount, awaitAnswer, pendingElicitationIds (the multitool reaches wait/cancel through ToolContext).
    - MountSite (struct) with public init(sessionID:runPlane:sink:op:tracer:); its properties stay internal. ToolMounting (enum) with makeWrapped(tool:site:configuration:) (the router makeSessionMounted).
    - ToolFailureDelivery (enum): makeWrapped(tool:), throwingTool(of:).
    - ToolDecorator (protocol) and its SubmissionBoundaryTool extension submissionWillBegin() (router TokenCappingTool).
    - PendingRunEnvelope: rendered, decoded(fromRendered:), and replacing(detail:) (added back for the router TokenCappingTool).
    - Already public before this task: BackgroundTool, ToolMount, ToolMountError, SubmissionBoundaryTool, LostRunError, RunKind, BackgroundRun, WaitOutcome, CancelOutcome, ElicitationAnswerDelivery, ElicitationCompletionDelivery, ToolCallAttachment, ToolCallReport, the seam protocols.
    - The 5 `// periphery:ignore` markers that named ^ebtprdg (ToolContext mount x2, makeCompletionToken; RunPlane.settledRunTokens) are removed. Periphery 3.8.0 (--retain-public, test targets report-excluded) reports nothing in Hosting/.

    Router tests copied (SessionMailbox -> RunPlane):
    - ToolContextTests (@testable): all 23 tests. trackFakeRun -> FakeRun.start; ToolCallAttachmentBox -> ToolCallState (attach, drainAttachments); the stamping init -> the memberwise init, and ToolContext(calling:on:...) for the empty-name test; the bounded poll -> AwaitedCondition under a suite time limit; guard -> #require(settledTerminal / alreadySettledTerminal).
    - ToolContextMountTests (@testable): all 8 tests.
    - ToolContextMountSinkPublicSurfaceTests (plain import): all 4 tests. The router drove a ScriptedSessionFixture only to get a bound context; here the host tool is mounted on a new RunPlane with the public ToolMounting.makeWrapped, as a host does. The CallBarrier actor is replaced by two latches (RunLatch.closed()), no new type; the background test now waits until the run posted its progress before it reads the sink.
    - ToolContextTokenPublicSurfaceTests (plain import): both tests, plus one that RunPlane.makeCompletionToken() is public.
    - ToolMountingTests (@testable): all 12 tests. makeWrapped(inheriting:) -> ToolContext.mount(_:as:postingTo:); makeSessionMounted -> ToolFailureDelivery over ToolMounting.makeWrapped with the synchronous mount (no capping layer: a nil limit adds none in the router).
    - New: ToolHostingPublicSurfaceTests (plain import, 11 tests: RunPlane observer/settled tokens/sweep/respond/complete, a host-made context with $current, failure delivery, a decorator written outside the package, envelope decode and replacing(detail:)), ToolHostingReadmeTests (the README example).

    Router tests NOT copied (each needs a RoutedSession):
    - MountedRunAttachmentCarrierTests: reads SessionEvent.toolCallReport from RoutedSession.streamEvents (ScriptedSessionFixture).
    - MountedRunSweptTerminalTests: RoutedSession.close() sweeps and journals; RouterTestFixtures.makeRouter.
    - NestedRunTerminalForwardingTests: the session journal and the session event stream of a RoutedSession.
    - ElicitationRoutingTests: RoutedSession.respond(elicitationId:response:)/complete(elicitationId:) over a Router. The RunPlane half (respond, complete, URL accept, duplicate and unknown ids) is covered by RunPlaneActorTests (task ^dxra4d9) and ToolHostingPublicSurfaceTests.

    OperationVocabulary.swift decision: it stays in the router, and it is not copied. It is only public typealiases (OperationEvent, OperationEventSink, ElicitationRequest, ...) that re-export Extras names under the router module, so that router clients keep their spelling. It uses no router type, but in Extras the names are the declarations themselves, so a copy has no purpose. The router removal task decides if it keeps them.

    Docs: README "Tool hosting: ToolContext and RunPlane" section with a short background-tool example (RunTests + Wait tools, mount on a RunPlane, sweep), mirrored by readmeBackgroundToolExample; plan.md §6 has the router tool-hosting use and a new FoundationModelsMultitool row.

    Note for the multitool: its tests use SessionMailbox.track/updateProgress/wait/sweep through @testable import of the router. These stay internal in Extras, so those tests need a change (for example a real mount or a public host path) when the multitool moves to Extras.
  timestamp: 2026-09-27T02:17:43.162980+00:00
- actor: claude-code
  id: 01m3gaf509zatdgsaedes7n2yn
  text: |-
    Correction to the counts in the comment above: ToolContextTests has 22 tests (router 22), and ToolHostingPublicSurfaceTests has 10 tests.

    ### implement — changed
    - evidence: Sources/FoundationModelsExtras/Hosting/{ToolContext,RunPlaneActor,ToolMounting,ToolFailureDelivery,ToolDecorator,PendingRunEnvelope}.swift (public API, 5 periphery markers removed, replacing(detail:) added); new Tests/FoundationModelsExtrasTests/Hosting/{ToolContextTests,ToolContextMountTests,ToolMountingTests,ToolContextMountSinkPublicSurfaceTests,ToolContextTokenPublicSurfaceTests,ToolHostingPublicSurfaceTests,ToolHostingReadmeTests,MountingFixtures}.swift; MountFixtures.swift and RunPlaneTestSupport.swift (RunLatch.closed()); README.md (Tool hosting section); plan.md §6. RED seen first (plain-import files did not compile: ToolContext/RunPlane not in scope). `swift build`: 0 warnings, 0 errors. `swift test`: all pass (main run 720 tests in 66 suites; the other runs 396, 125, 44, 34, 26). Hosting suites (173 tests in 21 suites) 10 of 10 green with --skip-build, about 3.1 s each. swiftlint (missing_docs, no_magic_numbers, force rules) 0 violations; swiftformat idiom roster 0 findings; periphery: nothing in Hosting/. Router not changed. Not committed.
    - next: /review
  timestamp: 2026-09-27T02:17:53.929602+00:00
- actor: claude-code
  id: 01m3gbbek1bmspy784ev1jebra
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 1 finding (1 confirmed, 5 refuted) — Sources/FoundationModelsExtras/Hosting/PendingRunEnvelope.swift:127 (swift/fluent-usage). No finding asks for a lock, semaphore, gate, actor or router complexity, so no conflict with the user decision.
    - next: rename `decoded(fromRendered:)` to `makeDecoded(fromRendered:)` and update each caller; then review again.
  timestamp: 2026-09-27T02:33:21.249425+00:00
- actor: claude-code
  id: 01m3gbbs1q1n9ebsbsnwsnv3hw
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — public tool-hosting API, 5 copied router test files, public-surface and README tests, README, plan.md
    - test: green — swift test, 720 passed, 0 warnings, 0 skipped
    - commit: e0924fb
    - review: findings — Sources/FoundationModelsExtras/Hosting/PendingRunEnvelope.swift:127
  timestamp: 2026-09-27T02:33:31.959167+00:00
- actor: claude-code
  id: 01m3gbhw6s7g9zgkyxenxwte8v
  text: |-
    Finding fixed: `PendingRunEnvelope.decoded(fromRendered:)` is now `makeDecoded(fromRendered:)`. Changed: the declaration, the call in `isRendered(text:)`, the doc reference on `rendered`, and the 2 test callers (ToolHostingPublicSurfaceTests, ToolHostingReadmeTests). README.md, plan.md and Examples have no caller. RED seen first: the tests did not compile ("type 'PendingRunEnvelope' has no member 'makeDecoded'").

    Scan of the other public static methods in Sources/FoundationModelsExtras/Hosting/ for the same cause (a factory without `make`):
    - `ToolFailureDelivery.makeWrapped(tool:)`, `ToolMounting.makeWrapped(tool:site:configuration:)`, `RunPlane.makeCompletionToken()`, `ToolContext.makeCompletionToken()`: they start with `make`.
    - `ToolFailureDelivery.throwingTool(of:)`: not a factory. It returns the tool that already exists beneath the decorator (an accessor, a noun phrase with no side effect). No change.
    - `PendingRunEnvelope.defaultCollectInstruction(forCompletionToken:)`, `defaultResultInstruction(forCompletionToken:)`: they return text with no side effect (a noun phrase), not an instance of a type. No change.
    - `PendingRunEnvelope.isRendered(text:)`: a Boolean query. No change.
    - `ToolMount.synchronous`, `ToolContext.current`, `ToolResultAppendBoundary.current`: static properties, not methods. No change.
    Note for the router removal task: the router TokenCappingTool calls `decoded(fromRendered:)`. When the router uses Extras, it must call `makeDecoded(fromRendered:)`.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/Hosting/PendingRunEnvelope.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolHostingPublicSurfaceTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolHostingReadmeTests.swift. `swift build`: 0 warnings, 0 errors. `swift test --filter Hosting`: 11 tests in 2 suites passed. All 24 Hosting test files (filter by file name): 173 tests in 21 suites passed. Not committed.
    - next: /review
  timestamp: 2026-09-27T02:36:51.801166+00:00
depends_on:
- 01M3FP9WTFQEQZ8Q4YJDXRA4D9
position_column: doing
position_ordinal: '80'
title: 'Tool hosting 4: make the tool-hosting API public, copy the ToolContext and mount tests, and document it'
---
## Why
Fourth and last of the tool-hosting tasks in Extras (decision 2026-09-26: the router `Hosting/` folder moves into the core `FoundationModelsExtras` target; no new product or target). After this task, the router and the multitool can use tool hosting from Extras. The router session then makes the router task that removes `Hosting/` from the router.

## What to do
1. Make public the API that the router and the multitool use. Much of it is internal now. The multitool uses:
   - `ToolContext`: `current`, `post`, `progress`, `elicit`, `backgroundRuns`, `wait`, `cancel`, `mount`.
   - `BackgroundTool`, `ToolMount`, `SubmissionBoundaryTool`, `LostRunError`.
   - `RunPlane.makeCompletionToken()` (in the router: `SessionMailbox.makeCompletionToken()`).
   For the router, read each use of these types in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/` outside `Hosting/`, and make public each member that the router uses. Record the list on the task.
2. Give each new public declaration a doc comment.
3. Copy these router tests into `FoundationModelsExtrasTests`, and change `SessionMailbox` to `RunPlane`: `ToolContextTests`, `ToolContextMountTests`, `ToolContextMountSinkPublicSurfaceTests`, `ToolContextTokenPublicSurfaceTests`, `ToolMountingTests`, `MountedRunAttachmentCarrierTests`, `MountedRunSweptTerminalTests`, `NestedRunTerminalForwardingTests`, `ElicitationRoutingTests`. Copy only the tests that do not need a `RoutedSession`. For each test file that you do not copy, record the reason on the task. Do not change the router tests. The router keeps its tests until its removal task, so that the router proves no change in behavior.
4. Decide if `Hosting/OperationVocabulary.swift` (81 lines, router glue that imports Extras) stays in the router. Record the decision and the reason on the task. Do not copy it if it uses router types.
5. Add a "Tool hosting" section to `README.md`: the purpose, `ToolContext`, `BackgroundTool`, `ToolMount`, `SubmissionBoundaryTool`, the `RunPlane` actor, and a short example of a background tool.
6. Record in `plan.md` §6 (Known consumers) that the router and the multitool use tool hosting.
7. Keep each comment that tells why a construct is necessary. Do not change the cancellation code.

## Acceptance criteria
- [x] Each member in the multitool list above is public, with a doc comment.
- [x] The public-surface tests pass from `FoundationModelsExtrasTests` with only `import FoundationModelsExtras` (no `@testable`) for the public members.
- [x] The copied tests pass. `swift build` and `swift test` pass.
- [x] `README.md` has the "Tool hosting" section.
- [x] The task records the list of public members, the tests that were not copied, and the `OperationVocabulary` decision.

## Note on names
The router has public types with the same names (`ToolContext`, `BackgroundTool`, and others). When the router pins an Extras commit that has these public types, the router must remove its own `Hosting/` in the same change, or the names are ambiguous. The router session makes that task.

#tool-hosting #cross-repo

## Review Findings (2026-09-26 21:21)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 16 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `plan.md` — no validator matches this file

- [x] `Sources/FoundationModelsExtras/Hosting/PendingRunEnvelope.swift:127` `swift/fluent-usage` — Factory methods should start with `make`. The static method `decoded(fromRendered:)` reads as a parsing operation that creates a new PendingRunEnvelope instance, which is a factory method. Rename to `makeDecoded(fromRendered:)` to signal that this is a factory method creating a new instance.
