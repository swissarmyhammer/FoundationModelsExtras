---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fpr8p9de6zerq14kts3j06
  text: |-
    ### Design change (user, 2026-09-26): no RaceGate in the hosting code
    Replace each router use of `RaceGate` when you move the code:
    - Start gate in `BackgroundToolRunner`: remove it. Give the run plane a `start(tool:op:kind:completionToken:body:)` call that records the run and THEN makes the work task, in one actor call. The body is a non-isolated closure, so it runs outside the actor, and it keeps the caller's task-locals.
    - Grace wait in `BackgroundToolRunner.settledEnvelope`: remove the gate and its two tasks. Use `runPlane.wait(completionToken:seconds: grace)` and take `.settled(terminal)`.
    - `AuthoritativeStopReport` in `ToolRun`: remove it. `stop(using:)` makes `Task { await canceler() }`, stores the first one in a `Mutex<Task<OperationOutcome, Never>?>`, and awaits it. The settlement awaits the stored task's value, or uses `nil` when no stop started.
    - Timeout race in `ToolRun`: use the internal `Promise` (from task 01M3FN9KTQA9S37VTZXMMSRS07) in one function `resultOrTimeout(of:seconds:)`, with a doc comment that tells why it does not wait for the tool to stop after a timeout.
    This replaces "a diff shows only renames" in the acceptance criteria for these 4 places. The behavior stays the same, except that a cancel during the grace wait now returns the pending envelope at once.
  timestamp: 2026-09-26T20:33:21.097535+00:00
- actor: claude-code
  id: 01m3g3g2h9zav7sjqwdhz803y7
  text: 'Added requirement from ^gezqgmd (Tool hosting 1): copy the router tests `LostRunErrorTests` and `DeclaredRunKindTests` in this task. They need `RunToCompletionRunner`, `BackgroundToolRunner`, `BackgroundTool`, `ToolContext` and `SessionMailbox`, which did not exist in Extras in task 1, so task 1 could not compile them. Also: in Extras, `ToolCallSpan` keeps its own names (`ToolCallSpan.name`, `ToolCallSpan.AttributeKey`, `ToolCallSpan.ToolRunKind`) in place of `RouterTracing`, and `ToolResultAppendBoundary` is a struct made with `init(receive:)`, a closure, in place of a `RoutedSessionActor`.'
  timestamp: 2026-09-27T00:16:04.137354+00:00
- actor: claude-code
  id: 01m3g5gqq3z0mayjr79kevanrr
  text: |-
    ### User direction (2026-09-26) — this replaces "a copy with no change" and "a diff shows only renames"
    The user rejected the router's complexity: "in my mind this is still a pretty simple work queue in front of a shared model, but when i read the code you are burying me in complexity", and "i just want you to do a better job".
    - Keep the BEHAVIOR. The copied router tests are the proof, with no change to what they assert.
    - Write the CODE as simply as you can. You may restructure, merge or split types when the tests stay green. Short doc comments about this code only; no router history, no design-section references.
    - No lock, semaphore, gate or one-shot types other than the internal `Promise` (from the Mailbox task) and `Mutex`/`Atomic`. The "no RaceGate" comment above says how to replace each RaceGate use.
    - Report the line count of each file, router vs Extras.
  timestamp: 2026-09-27T00:51:22.979670+00:00
- actor: claude-code
  id: 01m3g5vn72ev6j1rbj0nwwm07n
  text: |-
    Research (implement start):
    - All dependencies are in Extras: OperationEvent, OperationEventSink (post(invocation:)), ToolInvocationRecord.closed(at:), ElicitationRequest/Response/Mode, ModelCallMark.withBackgroundRunMark, SerialAsyncChain, Promise, ToolCallSpan, PendingRunEnvelope, BackgroundTool, ToolMount, the RunPlane.swift value types (RunKind, BackgroundRun, WaitOutcome, CancelOutcome), HostingSeams (ToolCallReportSink, BackgroundRunSettlementObserver, StagedEventWithdrawing).
    - The 2 router ToolFailureDeliveryTests that need ToolMounting call `ToolMounting.makeSessionMounted(... cappedToTokenLimit:tokenCounter:)`. That function is in the router `Session/ToolOutputCapping.swift`, not in `Hosting/`, and it uses the router TokenCappingTool. Plan: copy both tests with no capping layer (ToolFailureDelivery over ToolMounting.makeWrapped): the decorator is outermost, and a failed call through the whole mount is a tool result. The capping argument (tokenLimit != nil) cannot be copied: it needs the router TokenCappingTool.
    - Router tests that cannot be copied: SessionMailboxTests close()/fork()/restore tests (5, need RoutedSession/Router); BackgroundToolRunnerTests `tokenCappingPassesRenderedEnvelopesThrough` and `tokenCappingCutsOnlyTheDetailOfASettledEnvelope` (router TokenCappingTool). `inlineResultWithdrawsWhatTheRunStaged` uses the router SessionOutbox; it is copied with a small test sink that stages events and conforms to StagedEventWithdrawing, so the withdrawal assertion stays.
    - Design (user direction: simple): RunPlane keeps one list of open runs and one map of settled terminals. `start(tool:op:kind:completionToken:canceler:body:)` records the run and makes the work task in one actor call; a nil canceler means the cooperative one (cancel the work task, report .cancelled). `wait` races the run's Promise, the deadline and task cancellation through one Promise (no waiter map). Elicitations are one ordered list, each with a Promise. ToolRun: `stop(using:)` stores the first stop Task in a Mutex; `resultOrTimeout(of:)` races with a Promise.
  timestamp: 2026-09-27T00:57:20.866976+00:00
- actor: claude-code
  id: 01m3g6vh483kv866svcje1tman
  text: |-
    Implementation landed (user direction: same behavior, simpler code). Not committed.

    Line counts, router -> Extras (Sources/FoundationModelsExtras/Hosting/):
    - ToolContext 515 -> 295
    - SessionMailbox 508 -> RunPlaneActor 405 (actor RunPlane)
    - ToolRun 401 -> 364 (also holds ToolCallState and RunEventFunnel)
    - BackgroundToolRunner 255 -> 130
    - ContextBindingTool 163 -> 105
    - RunToCompletionRunner 102 -> 61
    - ToolMounting 86 -> 65 (also holds MountSite)
    - Total 2030 -> 1425
    Also HostingSeams.swift: one doc line, "session mailbox" -> "run plane".

    The RaceGate uses are gone, as the design comment says:
    - Start gate: `RunPlane.start(tool:op:kind:completionToken:canceler:body:)` records the run and makes the work task in one call that does not suspend. A nil canceler is the cooperative one: it cancels the work task and reports .cancelled (the cancellation handler of the run sets the cooperative flag).
    - Grace wait: `runPlane.wait(completionToken:seconds: grace)`, take `.settled(terminal)`.
    - AuthoritativeStopReport: `ToolCallState.stop(using:)` keeps the first `Task { await canceler() }` in a `Mutex<Task<OperationOutcome, Never>?>`; the settlement awaits its value, or nil.
    - Timeout race: `ToolRun.resultOrTimeout(of:)` with the internal Promise; its doc tells why it does not wait for the tool to stop.
    Other simplifications: RunPlane keeps one ordered list of open runs (each with a Promise for its terminal event) and one map of settled terminals; `wait` is a race of three through one Promise (no waiter map, no UUIDs). Elicitations are one ordered list, each with a Promise. The funnel owns the timeout watch loop (no TimeoutCheckpoint type). The cancel flag, the attachment box and the stop report are one class, ToolCallState (Atomic + Mutex). The three decorators take one MountSite (session, run plane, sink, op, tracer) in place of 5 parameters.

    Behavior differences (each on purpose, the tests stay the same):
    - A cancel of the caller during the grace wait returns the pending envelope at once (as the design comment said).
    - A second `stop(using:)` waits for the first stop and does not run the canceler again.
    - A wait that ends at its deadline or at a cancel leaves one small task that waits for the settlement; it ends when the run settles (the sweep settles each run).

    Tests (Tests/FoundationModelsExtrasTests/Hosting/): RunPlaneActorTests (the non-session SessionMailboxTests, plus 2 sweep tests at plane level in place of the 5 close()/fork()/restore tests that need a RoutedSession), RunPlaneTests, RunToCompletionRunnerTests, BackgroundToolRunnerTests (all but the 2 TokenCappingTool tests; the withdraw test uses a small staging sink in place of SessionOutbox), LostRunErrorTests, DeclaredRunKindTests, and 2 ToolFailureDeliveryTests over ToolMounting (no capping layer: makeSessionMounted and TokenCappingTool are router Session code). Fixtures: MountFixtures.swift, RunPlaneTestSupport.swift (RunLatch = Promise<Void>, FakeRun.start, AnswerDrivenRun, AwaitedCondition). No `guard` in a test: `#require(result.settledTerminal)`.
    Staged API with no caller in this task (mount x2, MountedRunUpstreamSink, ToolContext.makeCompletionToken, RunPlane.settledRunTokens) has a `// periphery:ignore` marker with the reason (task ^ebtprdg).
  timestamp: 2026-09-27T01:14:45.256667+00:00
- actor: claude-code
  id: 01m3g6vm83zvh99wv8pgeg1faa
  text: |-
    ### implement — changed
    - evidence: 7 new source files in Sources/FoundationModelsExtras/Hosting/ (1425 lines, router 2030), HostingSeams.swift (1 doc line), 8 new test files + ToolFailureDeliveryTests.swift (2 tests) in Tests/FoundationModelsExtrasTests/Hosting/. RED seen first (test target did not compile: RunPlane missing). `swift build` and `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: all pass (main run 658 tests in 59 suites; the other targets pass). The 7 hosting suites (82 tests) ran 10 times with --skip-build: 10 of 10 green, about 2.2 s each. Router not changed. Not committed.
    - next: /review
  timestamp: 2026-09-27T01:14:48.451053+00:00
depends_on:
- 01M3FP9FGARYJFK9NYQMRY5QM0
position_column: doing
position_ordinal: '80'
title: 'Tool hosting 3: move the run plane core (ToolContext, the run-plane actor, ToolRun, the runners, ContextBindingTool, ToolMounting)'
---
## Why
Third of 4 tool-hosting tasks (decision 2026-09-26: the router `Hosting/` folder moves into the core `FoundationModelsExtras` target; no new product or target).

These 7 files depend on each other in a loop (a check of the code, not the comments):
- `ToolContext` uses `SessionMailbox` and `ToolMounting`.
- `SessionMailbox` uses `ToolContext`.
- `ToolMounting` uses `BackgroundToolRunner`, `ContextBindingTool` and `RunToCompletionRunner`.
- `BackgroundToolRunner`, `RunToCompletionRunner` and `ContextBindingTool` use `ToolRun` and `SessionMailbox`.
- `ToolRun` uses `ToolContext`.
Thus no part of this group can build without the other parts, and this task moves all 7 files together (about 2,030 lines). The move is a copy, with no change to behavior. This is larger than the usual limit of 500 lines, because a smaller split cannot build. Task 01M3FPA83C04HNESZYBEBTPRDG (tool hosting 4) makes the public API and copies the remaining tests.

## What to do
Source: `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Hosting/`. Destination: `Sources/FoundationModelsExtras/Hosting/`.
1. Copy these files:
   - `ToolContext.swift` (515).
   - `SessionMailbox.swift` (508).
   - `ToolRun.swift` (401).
   - `BackgroundToolRunner.swift` (255).
   - `ContextBindingTool.swift` (163).
   - `RunToCompletionRunner.swift` (102).
   - `ToolMounting.swift` (86).
2. Rename the tool-run actor `SessionMailbox` to `RunPlane` in Extras (file `RunPlaneActor.swift`). Reason: Extras also has `Mailbox` (messages to a session, task 01M3FN9KTQA9S37VTZXMMSRS07), and two "mailbox" types with different jobs are confusing. The files already use "run plane" for this concept. Do not add a `SessionMailbox` typealias in Extras. The router can add its own typealias if it needs one.
3. Keep the API internal in this task, except where a type of task 01M3FP9FGARYJFK9NYQMRY5QM0 needs it. Task 01M3FPA83C04HNESZYBEBTPRDG makes the public API.
4. Change doc comments that name `RoutedSession`, `SessionEvent` or `SessionOutbox` to general words.
5. Keep each comment that tells why a construct is necessary. The router has cancellation invariants that prevent a model-wide deadlock and the silent loss of messages. Do not simplify them. Do not change the order of the steps in the cancellation paths.
6. Copy these router tests into `FoundationModelsExtrasTests`, and change `SessionMailbox` to `RunPlane`: `SessionMailboxTests` (as `RunPlaneActorTests`), `RunPlaneTests`, `RunToCompletionRunnerTests`, `BackgroundToolRunnerTests`. Only copy tests that do not need a `RoutedSession`. Do not change the router tests.

## Acceptance criteria
- [ ] The 7 files are in `Sources/FoundationModelsExtras/Hosting/`, and the actor has the name `RunPlane`.
- [ ] A diff against the router files shows only the rename, access-level changes and doc-comment wording. The cancellation code is the same.
- [ ] No doc comment names a router type.
- [ ] The copied tests pass. `swift build` and `swift test` pass.

#tool-hosting #cross-repo