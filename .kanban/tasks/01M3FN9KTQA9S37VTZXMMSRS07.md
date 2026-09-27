---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fpr2sr1abdjff7qpw4kt6f
  text: |-
    ### Design change (user, 2026-09-26): no RaceGate
    `RaceGate` is not in Extras. The one-time answer slot of the Mailbox (the router `PumpAnswer`) uses a small internal type `Promise<Value>`: `fulfill(_:)` (the first call wins, later calls do nothing) and `var value: Value { get async }` (any number of waiters; the wait is not cancellable, the same as `Task.value`). Add `Promise` in this task, internal, in about 30 lines, with tests: a value before the wait, a value after the wait, two waiters, and a second fulfill that does nothing. Keep the code simple and the doc comments short.
  timestamp: 2026-09-26T20:33:15.064883+00:00
- actor: claude-code
  id: 01m3fxvvg5552zr5n7a9m6z5ga
  text: |-
    ### Research (implement)
    - Router behaviors to keep: FIFO; the first waiting message decides the batch, and each later message that can share it comes too (router: a stream goes alone; same token ceiling). cancel: waiting -> `.withdrawn` and the poster gets CancellationError; taken -> `.cancelledInSubmission`; answered or unknown -> `.alreadyAnswered`. replace: waiting -> `.applied`, else `.alreadySent`. depth: waiting count + ids of the running batch.
    - The router needs the cancel mark (`PumpAnswer.requestCancel`) and the "cancel before enqueue" handler only because its enqueue suspends (actor hop to the outbox). In Extras, post, cancel and take are synchronous under one Mutex, so these races cannot occur and the marks are not necessary.
    - New design: `Mailbox` = final class, one `Mutex` (waiting letters, running letters, doorbell). The pump calls `answerNextBatch(joining:_:)`: it waits (a new one-shot AsyncStream as doorbell for each wait), takes the batch, runs the body, and gives the result to each letter of the batch. So a taken letter always gets an answer, also when the pump task is cancelled (the body throws). A pump cancelled while it waits takes nothing.
    - The router continuation "join the running answer" (`takeJoiningBatch`) is not in this task. The router task can add it when it needs it.
  timestamp: 2026-09-26T22:37:38.693822+00:00
- actor: claude-code
  id: 01m3g157f0w6m3bkqpcxk2df30
  text: |-
    ### Implementation landed
    New files (a new small design, no router code copied):
    - `Sources/FoundationModelsExtras/ModelPool/Mailbox.swift` (204 lines, 115 code lines): `Mailbox<Message, Answer>`, a final class with one `Mutex` state (waiting letters, running letters, doorbell). API: `post(_:) -> (id, answer)`, `postAndWait(_:)`, `cancel(_:)`, `replace(_:with:)`, `pending`, `depth`, `answerNextBatch(isolation:joining:_:)`. Also `MailboxAnswer<Value>` (public wrapper with `value`), because `Promise` stays internal.
    - `Sources/FoundationModelsExtras/ModelPool/Promise.swift` (58 lines, 42 code lines): internal `Promise<Value>`: `fulfill(_:)` (first wins), `value` (any number of waiters, not cancellable), `waiterCount`.
    - `Sources/FoundationModelsExtras/ModelPool/MessageQueue.swift` (63 lines, 26 code lines): `MessageID` (ULID), `MessageQueueMutationResult`, `MessageCancellationResult`, `MessageQueueDepth` (same names and cases as the router).
    - Tests: `Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift` (24 tests: the router `MessageQueueTests` that apply to a generic queue, adapted, plus the acceptance tests, the joining rule, the deinit, and the README example) and `PromiseTests.swift` (4 tests).
    - README: new section "Posting to a session: `Mailbox`", and the intro line.

    Design notes for the router task ^ (01M3FNC92WA10NG6TX59H3RKXF):
    - The pump doorbell is a new one-shot `AsyncStream` for each wait; `post` finishes it. A pump cancelled while it waits takes nothing.
    - `answerNextBatch` gives the result of the body to each letter of the batch, also when the body throws or the pump task is cancelled. So a taken letter always gets an answer.
    - `cancel` of a letter in the running batch gives it `CancellationError` at once and returns `.cancelledInSubmission`. The mailbox does not stop the body; the router must cancel its own running work on that result.
    - The router cancel mark (`PumpAnswer.requestCancel`) is not necessary here: post, cancel and take are synchronous under one lock.
    - NOT in this task: a non-waiting "join the running answer" take (router `takeJoiningBatch`). The router task must add it if it needs continuations to take new messages.
    - Router-only tests not copied (mail preamble, settled-run delivery, progress-only mail, prompt flattening, submission frames, ids and usage): they test router features that stay out of the mailbox.

    ### What did not work
    - First version of `pumpCancelledWhileItsBodyRuns` hung about 1 run in 24: the test started the pump before it posted two messages, so the pump could take "first" alone, and "second" then waited (correctly) with no pump. Fix: post both messages before the pump starts. After the fix, 40 of 40 repeated runs passed.
    - Side effect during the hang search: `pkill -f swiftpm-testing-helper` also stopped a test helper of another project (FoundationModelsMultitool IntegrationTests, pid 58657). Later kills used the exact bundle path of this package only.
  timestamp: 2026-09-26T23:35:11.584250+00:00
- actor: claude-code
  id: 01m3g15c1spdwmfsxq1q6mpzmy
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/ModelPool/Mailbox.swift (204 lines), Sources/FoundationModelsExtras/ModelPool/Promise.swift (58), Sources/FoundationModelsExtras/ModelPool/MessageQueue.swift (63), Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift (548), Tests/FoundationModelsExtrasTests/ModelPool/PromiseTests.swift (49), README.md. `swift build` (clean scratch build): 0 warnings. `swift test`: all runs pass (521 + 393 + 125 + 44 + 34 + 26 tests, 0 failures). `swift test --filter "MailboxTests|PromiseTests"` repeated 40 times: 40 of 40 pass (28 tests each).
    - next: /review. Task stays in `doing`. Not committed, not pushed.
  timestamp: 2026-09-26T23:35:16.281854+00:00
- actor: claude-code
  id: 01m3g17q3jm9q03fv8c6cphygj
  text: |-
    ### Added requirement (router session, 2026-09-26): take messages that join the running batch
    Router task 01M3FNC92WA10NG6TX59H3RKXF needs this (from the router `SessionOutbox.takeJoiningBatch(options:)` and `takeMessagesJoiningTheAnswer()`).
    - [ ] Add `public func takeJoining(admitting: (Message) -> Bool) -> [Letter]` to `Mailbox`. It does not wait and does not suspend.
      - It is valid only while `answerNextBatch` runs a batch. Keep a `Bool` in the state for "a batch runs" (do not use `running.isEmpty`, because a cancel can empty `running` while the batch still runs). With no running batch it returns `[]`.
      - Under ONE lock step: take each WAITING letter for which `admitting` returns true, in FIFO order; the other letters keep their order; append the taken letters to `running`.
      - A message that its poster cancelled is already out of `waiting` (cancel removes it and gives `CancellationError`), so the take never returns it. Keep it so: no suspension between the check and the join.
      - The joined letters get the same final result as the batch (the same answer, or the same error), because `answerNextBatch` fulfills every letter in `running`.
      - After the join, `cancel(id)` of a joined letter returns `.cancelledInSubmission`.
      - An empty result is not an error.
    - [ ] Tests: (a) a message posted while a batch runs and taken with `takeJoining` gets the final answer of the batch; (b) a message that the predicate refuses stays waiting, in order; (c) a message cancelled before the take gets `CancellationError` and is not returned; (d) `cancel` of a joined message returns `.cancelledInSubmission`; (e) with no running batch, `takeJoining` returns `[]`; (f) a batch that throws gives the error to the joined messages too.
    - Keep it small, in the style of the rest of `Mailbox`. No new types.
  timestamp: 2026-09-26T23:36:33.138568+00:00
- actor: claude-code
  id: 01m3g2jr8jsz361y6h4p99trre
  text: |-
    ### Added requirement done: takeJoining(admitting:)
    - `Mailbox.takeJoining(admitting:) -> [Letter]`: one lock step, no suspension. Guard on the new `State.isBatchRunning` (set in `nextBatch` when the batch is taken, cleared in `answerNextBatch` in the same lock step that empties `running`). Waiting letters that `admitting` accepts move to `running`, in FIFO order. The others keep their order. No new types.
    - `admitting` runs ONE time for each waiting letter (map to (letter, joins), then partition). Reason: a router predicate can keep state (for example a token budget). Two calls for each letter (filter + filter) would ask the budget two times.
    - The class doc now names `takeJoining` in the list of the operations that occur under one lock.
    - Tests (in MailboxTests, section "Messages that join the running batch"): (a) joinedMessageGetsTheAnswerOfTheBatch, (b) refusedMessageStaysWaitingInOrder, (c) messageCancelledBeforeTheTakeIsNotReturned, (d) cancelOfAJoinedMessageReportsCancelledInSubmission, (e) takeJoiningWithNoRunningBatchReturnsNothing (before any batch, and after a batch ended, so the flag is cleared), (f) failedBatchGivesItsErrorToTheJoinedMessages (private `BatchFailure` error).
    - README not changed: the added requirement does not ask for it.

    ### What did not work
    - RED run 1 hung: with a stub that returned `[]`, tests (a) and (f) waited on `joined.value` for ever. I stopped only my own two processes (swift-test pid 70237 and its swiftpm-testing-helper pid 70494), by pid. Fix: the take checks in (a), (d), (f) are `try #require`, so a regression fails the test at once and does not hang it.
    - RED run 2: (a), (b), (d), (f) failed as expected. (c) and (e) passed with the stub, because they check that the take returns nothing; they guard the real code (a flag that is not cleared, or a cancelled message that comes back).
  timestamp: 2026-09-27T00:00:03.346062+00:00
- actor: claude-code
  id: 01m3g2jtpkxyakfe3g430b33wg
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsExtras/ModelPool/Mailbox.swift (234 lines, was 204), Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift (667 lines, was 548; 6 new tests). `swift build`: 0 warnings, 0 errors. `swift test --skip-build --filter 'Mailbox|Promise'` repeated 20 times: 20 of 20 pass, 34 tests each, 0 warnings.
    - next: /review. Task stays in `doing`. Not committed, not pushed.
  timestamp: 2026-09-27T00:00:05.843343+00:00
- actor: claude-code
  id: 01m3g2xq3mpxt6sragyzj1egch
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (d143763). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. 5 files reviewed. README.md had no validator that matched it. The .kanban files were not reviewed because of .reviewignore.
    - next: The task is in done.
  timestamp: 2026-09-27T00:06:02.612725+00:00
- actor: claude-code
  id: 01m3g2y2y1ggrpx8trtjmdcwg8
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Mailbox (with takeJoining), Promise, MessageQueue types, 34 tests, README
    - test: green — swift test, 527 passed, 0 warnings, 0 skipped
    - commit: d143763
    - review: clean — task is done. The router pins d143763.
  timestamp: 2026-09-27T00:06:14.721438+00:00
depends_on:
- 01M3FN8WD0G0NJ7QAAKSPZ9RW1
- 01M3FN9BTXNPBWE6VVBQEXK4W2
position_column: done
position_ordinal: bd80
title: 'ModelPool: add a generic Mailbox that posts messages to a session asynchronously'
---
## Why
A caller must be able to post messages to a session asynchronously. The router does this today with `SessionOutbox`, but the outbox is tied to router types (`Transcript.Prompt`, `SessionEvent`, tracing, compaction, recording and tool hooks). This task makes a generic mailbox in the core `FoundationModelsExtras` target, in `Sources/FoundationModelsExtras/ModelPool/`. Do not add a new target. The name is `Mailbox`, because the router already has an internal `SessionMailbox` for tool runs.

## Source files
In `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/`:
- `SessionOutbox.swift` (422 lines).
- `SessionMessage.swift` (168 lines), including `PumpAnswer<Value>`, a one-time answer slot.
- `MessageQueue.swift` (79 lines): `MessageID`, `MessageQueueDepth`, and the cancel and replace results.
- `RoutedSessionActorPump.swift`: the pump.

## What to do
1. Add `Mailbox<Message, Answer>` (generic, `Sendable`). Operations:
   - `post` returns a `MessageID` and a one-time answer slot.
   - `cancel(MessageID)` and `replace(MessageID, with:)`, with the result types from `MessageQueue.swift`.
   - `depth`.
   - take-next-batch, for the pump of the consumer.
2. Do not move the router features into the mailbox. OperationEvent coalescing, progress coalescing, compaction, recording and tools stay in the router, as hooks around each batch.
3. Keep the cancellation invariants of the router pump. Read the comments in `SessionOutbox.swift` and `RoutedSessionActorPump.swift` before you start. The invariants prevent a model-wide deadlock and prevent the silent loss of outbox messages. Keep each comment that tells why a construct is necessary. Do not simplify the cancellation code.
4. Use only Foundation, `Synchronization` and the ULID package.
5. COPY the router tests of the queue semantics (for example `MessageQueueTests`) into the existing `FoundationModelsExtrasTests` target, and change them to use `Mailbox`. Do not remove or change the tests in the router. Router task 01M3FNC92WA10NG6TX59H3RKXF keeps `MessageQueueTests` with no change.
6. Add the `Mailbox` to `README.md`: the purpose, the operations and a short example.

## Acceptance criteria
- [x] The copied queue-semantics tests pass.
- [x] Test: each posted message gets exactly one answer, or a cancel result. No message is lost silently, also when the poster or the pump is cancelled.
- [x] Test: the answer slot of a message in a batch that was taken is cancelled. The next take-next-batch call still returns the messages posted after it, and no posted message is lost.
- [x] Test: `replace` and `cancel` on a message that is already taken give the correct result.
- [x] `README.md` describes the `Mailbox`.
- [x] The public API has doc comments. `swift test` passes.

Note: the criterion "a cancelled pump does not block the work queue of the model" moved to router task 01M3FNC92WA10NG6TX59H3RKXF, because a generic mailbox has no model queue.

#model-pool #cross-repo