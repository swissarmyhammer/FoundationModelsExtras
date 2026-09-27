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
depends_on:
- 01M3FP9FGARYJFK9NYQMRY5QM0
position_column: todo
position_ordinal: '8680'
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