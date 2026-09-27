---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fnknekr198rpc2neqse8jr
  text: |-
    ### Added requirements (router double-check, 2026-09-26)
    - [ ] Add the work queue (`GenerationQueue`, the re-entry guard, `onQueued`) to `README.md`: the purpose and a short example.
    - Push order: push the commit of this task separately, before the commit of 01M3FN95AM98RJSTCVQ8G1Z7KE. The router has its own public `ModelPool` today, so router task 01M3FNB4MCRRBTJNNVZZ6P02R2 must pin an Extras commit that has no `ModelPool` type. This task must not add a type with the name `ModelPool`. Pushing is a step that the user does or approves.
  timestamp: 2026-09-26T20:13:21.747944+00:00
- actor: claude-code
  id: 01m3fnnekrzb5twqr53q9c6msh
  text: |-
    Research done.
    - Source dependency set: GenerationQueue uses GenerationWorker, GenerationQueueError, ModelCallMark and ModelRef. GenerationReentry (ModelCallMark, SubmissionTarget) uses ULID, GenerationQueue and ModelRef. AsyncSemaphore and RaceGate use only Synchronization. No listed file uses SerialAsyncChain or CancellableWait (CancellableWait uses AsyncSemaphore, not the reverse). Thus these two files are not copied, as the card says ("if the files above use them").
    - The router ULID.swift adds a `ULID.generate()` shim. Extras imports the ULID package directly (`import ULID`), thus the copied code and tests use `ULID()`.
    - Router tests that are portable without MLX or a routed session: AsyncSemaphoreTests (all), GenerationQueueWorkerTests (first suite all; the second suite uses FoundationModels and the router SessionLanguageModel, thus it is rewritten as a task-local test with no SDK), the onQueued test of GenerationQueueTests, the ModelRef tests of CoreTypesTests, GenerationQueuePublicSurfaceTests, and the BoundedWait helper. GenerationQueueSubmissionTests, NestedGenerationReentryTests and the container tests of GenerationQueueTests need RoutedSession or MLX containers, thus they stay in the router.
    - The router has no RaceGate test. A new RaceGate test is added.
    - Extras tests use a plain `import FoundationModelsExtras` to hold the public surface. The copied tests do the same.
    - Added requirement from the coordinator: README section for the work queue, and no type with the name `ModelPool` (the router has its own public ModelPool).
  timestamp: 2026-09-26T20:14:20.280862+00:00
- actor: claude-code
  id: 01m3fpa9dsfb2nnd2p2618dpnw
  text: |-
    Implementation landed.
    - Sources/FoundationModelsExtras/ModelPool/: ModelRef, AsyncSemaphore, GenerationQueue, GenerationWorker, GenerationQueueError, GenerationReentry (ModelCallMark, SubmissionTarget), RaceGate. A diff with the router files, with the doc comments removed, shows only access changes (package/internal to public), a public init for SubmissionTarget and RaceGate, and `import ULID`. The cancellation code and the re-entry refusal are the same code. Each comment that tells why is kept; a DocC link to a router symbol became a plain code span ("the router `X`"), because DocC cannot resolve it in this package.
    - GenerationWorker and its Ticket stay internal: no consumer calls them.
    - SerialAsyncChain and CancellableWait are not copied: no copied file uses them.
    - Tests/FoundationModelsExtrasTests/ModelPool/: AsyncSemaphoreTests, GenerationQueueWorkerTests (+ the onQueued test from GenerationQueueTests + a task-local suite with no SDK), GenerationQueuePublicSurfaceTests (+ readmeWorkQueueExample), ModelRefTests, ModelCallMarkTests, RaceGateTests (new; the router had none), BoundedWait helper. All use a plain import. 41 new tests.
    - Mutation check: with the `refuseWaitInsideOpenSubmission()` call removed from submit, 2 tests fail (the refusal test and the README test). The line was put back.
    - README: new section "One model, one queue: GenerationQueue"; the intro names it. plan.md: §5 new rule bullet (decision 2026-09-26), §6 rows for FoundationModelsRouter and FoundationModelsMetadataRegistry, and the router paragraph no longer says the router consumes nothing.
    - Package.swift is unchanged. No type has the name ModelPool.
    - Note for the router tasks: the router module declares the same public names (ModelRef, GenerationQueue, AsyncSemaphore ...). Inside the router module its own declarations win over the imported ones, and only OperationVocabulary.swift imports FoundationModelsExtras there, thus no ambiguity occurs until the router deletes its copies.
  timestamp: 2026-09-26T20:25:43.097322+00:00
- actor: claude-code
  id: 01m3fpabpctrfa39bm25xv12x0
  text: |-
    ### implement — changed
    - evidence: 7 new sources in Sources/FoundationModelsExtras/ModelPool/, 7 new test files in Tests/FoundationModelsExtrasTests/ModelPool/, README.md, plan.md. `swift build`: 0 warnings, 0 errors. `swift test`: exit 0; FoundationModelsExtrasTests 488 tests in 41 suites passed (41 new), other targets 125 + 34 + 44 + 26 + 393 passed.
    - next: /review
  timestamp: 2026-09-26T20:25:45.420372+00:00
- actor: claude-code
  id: 01m3fpdh4v6zw3fdzpe91kcqna
  text: |-
    ### Commit and push order (router session, 2026-09-26)
    Each router step pins one Extras commit. Make the Extras commits in this order, and push each one separately (the user does or approves each push):
    1. 01M3FN8WD0G0NJ7QAAKSPZ9RW1 (queue). Router task 01M3FNB4MCRRBTJNNVZZ6P02R2 pins it.
    2. 01M3FN95AM98RJSTCVQ8G1Z7KE, then 01M3FN9BTXNPBWE6VVBQEXK4W2 (pool, embedder). Router tasks 01M3FNBKR2347W659AXFJVZKGM, 01M3FNJS6J7KGAJJ5WFEST00WA, 01M3FNK00PYXP7E102NWNHMD56 and 01M3FNBZF74DHSGE70C5339RGT pin the commit of 01M3FN9BTXNPBWE6VVBQEXK4W2.
    3. 01M3FN9KTQA9S37VTZXMMSRS07 (Mailbox; adds a public `MessageID`, and the router also has one). Router task 01M3FNC92WA10NG6TX59H3RKXF pins it.
    4. The 4 hosting tasks, last: 01M3FP9700G1GWA15B0GEZQGMD, 01M3FP9FGARYJFK9NYQMRY5QM0, 01M3FP9WTFQEQZ8Q4YJDXRA4D9, 01M3FPA83C04HNESZYBEBTPRDG. Router task 01M3FPCADD0GTFAV2RANXKE7G0 pins the commit of 01M3FPA83C04HNESZYBEBTPRDG.
    The task dependencies enforce this order. A hosting commit before step 2 or 3 puts public hosting types into an early router pin and makes names ambiguous.
  timestamp: 2026-09-26T20:27:29.307235+00:00
- actor: claude-code
  id: 01m3fpgkv8rnj6z2mvnh8n6t6f
  text: |-
    ### commit — changed
    - evidence: d682e45 feat(model-pool): move the work queue from the router into the core target
    - next: push is a step the user does or approves. Do it before the commit for task 01M3FN95AM98RJSTCVQ8G1Z7KE.
  timestamp: 2026-09-26T20:29:10.376633+00:00
- actor: claude-code
  id: 01m3fpqtphxqt603hsqer5v0re
  text: |-
    ### Design change (user, 2026-09-26): make the work queue simple
    The user said: "in my mind this is still a pretty simple work queue in front of a shared model, but when i read the code you are burying me in complexity" and "i just don't like race gate". This replaces the router request "keep every comment" and "do not simplify the cancellation code". Keep the BEHAVIOR. Rewrite the CODE.

    Do these changes on top of commit d682e45:
    - [ ] Remove `RaceGate.swift` and `AsyncSemaphore.swift` and their tests. The queue does not use them.
    - [ ] Remove `GenerationWorker.swift`. Rewrite `GenerationQueue` as one worker loop and one job type (target: about 100 lines with doc comments):
      - The queue holds an `AsyncStream<any QueuedJob>.Continuation`. `init` starts one `Task.detached` worker loop: `for await job in stream { await job.run() }`. `deinit` finishes the stream.
      - `Job<T>` holds one `Mutex` state: new → waiting(continuation) → running(task) → finished. All cancel rules are in this type. Only one path can resume the submitter.
      - `submit(isolation:onQueued:_:)` keeps its public signature (and the overload with no `onQueued`). It runs the re-entry refusal, makes the job, and in `withCheckedThrowingContinuation` gives the continuation to the job and yields the job. The `onCancel` handler calls `job.cancel()`.
      - `job.cancel()` is synchronous, on the task that cancels, with no actor: a new or waiting job becomes finished and the submitter gets `CancellationError` at once. A running job gets `task.cancel()` at once.
      - `job.run()` (only the worker calls it) skips a finished job. Otherwise it makes the job task with `Task.detached(priority: submitterPriority)` INSIDE `run()`, never in `submit`, so the job inherits no task-local of the submitter. It sets state running under the lock, awaits the task, and the task resumes the submitter one time.
      - `onQueued`, `isRunning` and `waitingCount` come from one `Atomic<Int>` count of the jobs that are not finished (a job that is cancelled while it waits does not count).
    - [ ] Make `GenerationReentry.swift` (`ModelCallMark`, `SubmissionTarget`) as small as possible, with the same behavior: a task-local reference to the open call on a queue, closed when the call returns; `withBackgroundRunMark` gives a closed mark; `refuseWaitInsideOpenSubmission()` throws `waitInsideOpenSubmission` at once.
    - [ ] Doc comments: short, and about this code. Remove the references to router design sections (`generation-queue.md`, section numbers) and the history text.
    - [ ] Update the README section and plan.md §5 for the removed types.

    Acceptance:
    - [ ] Every copied queue test passes with no change to what it asserts: FIFO, one job at a time, a cancel while waiting (the job never starts, also before any hop), a cancel while running (the task is cancelled at once), no inherited task-local, `onQueued`, and the re-entry refusal with the closed background mark. Remove only the tests of the removed types.
    - [ ] `swift build` has 0 warnings. `swift test` passes.
    - [ ] The ModelPool folder is about 250 lines in total, not 1,040.
  timestamp: 2026-09-26T20:33:06.769216+00:00
- actor: claude-code
  id: 01m3fprcqtv4c29qte8wggebx8
  text: |-
    ### finish iteration 1 — changed
    - implement: changed — 16 files (copy of the router queue)
    - test: green — swift test, 488 passed, 0 warnings
    - commit: d682e45
    - review: not run. The user rejected the copied design as too complex. The next iteration does the "Design change" comment above.
  timestamp: 2026-09-26T20:33:25.242286+00:00
- actor: claude-code
  id: 01m3fpxk20tk6g670bgr18rya0
  text: |-
    Iteration 2 picked up (design change "make the work queue simple").
    Research:
    - ModelPool folder before: 1,040 source lines (AsyncSemaphore 320, GenerationWorker 225, GenerationQueue 154, GenerationReentry 139, ModelRef 94, RaceGate 75, GenerationQueueError 33). Test folder before: 1,319 lines.
    - Only the tests use AsyncSemaphore (BoundedWait, GenerationQueueWorkerTests, AsyncSemaphoreTests). No source outside ModelPool uses AsyncSemaphore, RaceGate or GenerationWorker. README and plan.md §5 name them.
    - Added rule (coordinator): the word `AsyncSemaphore` must not occur in the package after the change, also not in test helpers, and no replacement semaphore or lock type is added. The test helpers use a flag (Atomic) and Task.sleep polling in its place.
    - Plan: Job<T> holds one Mutex state (new, waiting, running, finished). The unfinished count (Atomic<Int>) changes only in the state transitions of the job, under its lock: +1 at new -> waiting, -1 at waiting/running -> finished, before the submitter resumes. isRunning = count > 0, waitingCount = max(count - 1, 0). isRunning and waitingCount stay `get async`, so that the public API and the test `await` do not change.
  timestamp: 2026-09-26T20:36:15.552976+00:00
- actor: claude-code
  id: 01m3fqh4dbbmbqbn2g9bmwbwx7
  text: |-
    Iteration 2 implementation landed (design change "make the work queue simple"). Not committed.
    - Removed: AsyncSemaphore.swift, RaceGate.swift, GenerationWorker.swift, AsyncSemaphoreTests.swift, RaceGateTests.swift.
    - GenerationQueue.swift: one detached worker loop `for await job in stream { await job.run() }` over an `AsyncStream<any QueuedJob>`; `deinit` finishes the stream. `Job<T>` holds one `Mutex` state: new -> waiting(continuation) -> running(task) -> finished. `cancel()` is synchronous on the cancelling task: new/waiting -> finished, and a waiting submitter gets CancellationError at once; running -> `task.cancel()`. `run()` makes the job task with `Task.detached(priority:)` under the lock and sets `running` in the same lock step, so a cancel sees either `waiting` or `running`. The job task resumes the submitter after `finish()`. The one `Atomic<Int>` count of unfinished jobs changes only in these transitions (+1 at new -> waiting, -1 at -> finished, before the resume). `onQueued` is called on the submitter when the count before the job is > 0. `isRunning` = count > 0, `waitingCount` = max(count - 1, 0). Both stay `get async`, so the public API and the test `await` do not change.
    - GenerationReentry.swift: the same public API. One init; `withBackgroundRunMark` makes a copy of the current mark and closes it (no private init). No `import Foundation`.
    - Doc comments: short, about this code. No router design sections, no history (also removed from ModelRef and GenerationQueueError).
    - Tests: no assertion changed. Coordinator rule: the word `AsyncSemaphore` is gone from the package; the test helpers use a `Flag` (Atomic<Int>, not a lock) and `Task.sleep` polling. `BoundedWait.signalArrived` is removed; its one caller uses `conditionReached`. The `onQueued` test reads `Flag.count` (0 and 1) in place of `availablePermits` (0 and 1).
    - README: the paragraph about AsyncSemaphore/RaceGate is replaced with one about the worker loop and the job state. plan.md §5: the list of moved types no longer names the removed types.
    - Mutation check: with `job.cancel()` removed from `onCancel`, GenerationQueueWorkerTests fails (906 issues). Reverted. Note: `Task` in place of `Task.detached` inside `run()` does not fail the task-local test, because `run()` runs on the detached worker loop. The test guards the rule that the job task is not made in `submit`.
    - Line counts, ModelPool source folder: before 1,040; after 396 (GenerationQueue 195, GenerationReentry 90, ModelRef 89, GenerationQueueError 22). Code lines only (no comments, no blank lines): 207. The card target "about 250" holds for the code lines. With doc comments the total is 396. To go lower, the doc comments of public items must go, and the review rules require them. The user decides if 396 is acceptable. Test folder: 1,319 -> 824.
  timestamp: 2026-09-26T20:46:55.915560+00:00
- actor: claude-code
  id: 01m3fqh8fe91ry5b69ge15k5r8
  text: |-
    ### implement — changed
    - evidence: removed AsyncSemaphore.swift, RaceGate.swift, GenerationWorker.swift, AsyncSemaphoreTests.swift, RaceGateTests.swift; rewrote GenerationQueue.swift, GenerationReentry.swift; docs in GenerationQueueError.swift, ModelRef.swift; test helpers BoundedWait.swift, GenerationQueueWorkerTests.swift; README.md; plan.md §5. ModelPool sources 1,040 -> 396 lines (207 code lines). `swift build` 0 warnings, 0 errors (clean rebuild of both targets). `swift test` exit 0: FoundationModelsExtrasTests 473 tests in 39 suites passed; other targets 125 + 34 + 44 + 26 + 393 passed. `rg AsyncSemaphore`: no match. Not committed.
    - next: /review
  timestamp: 2026-09-26T20:47:00.078550+00:00
- actor: claude-code
  id: 01m3fr40zg5cpq7a7kjcx273wa
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~2..HEAD` (d682e45, 919caac). Counts: 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift:360 (`code-hygiene/idioms-swift` isEmpty). No finding asks to add back the removed complexity (RaceGate, AsyncSemaphore, GenerationWorker, history comments, router section references). README.md and plan.md had no validator.
    - next: correct the finding in the whole file, then /review again.
  timestamp: 2026-09-26T20:57:14.992791+00:00
- actor: claude-code
  id: 01m3fr4aby4nh3kavyyb2m6vpr
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — queue rewritten as one worker loop and one job type; RaceGate, AsyncSemaphore, GenerationWorker removed; ModelPool sources 1,040 -> 396 lines
    - test: green — swift test, 473 passed, 0 warnings, 0 skipped
    - commit: 919caac
    - review: findings — Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift:360
  timestamp: 2026-09-26T20:57:24.606775+00:00
- actor: claude-code
  id: 01m3fr9c78c2cvy8tp9kq9rapx
  text: |-
    Finding "isEmpty: Prefer isEmpty over comparing count against zero" corrected.
    - `holderWaits` is a test `Flag` (an Atomic<Int> count), not a collection. It has no `isEmpty`. The flag already has `isSet` (`count > 0`). Thus `#expect(holderWaits.count == 0)` became `#expect(!holderWaits.isSet)`. No new type and no new member.
    - Whole-file scan: that line was the only `.count` compared with zero. `Flag.isSet` itself is `count > 0`: it is the definition of the Boolean, and the type has no `isEmpty`. The `queue.waitingCount == 0` checks read a public `Int` property, not the `count` of a collection; `isEmpty` does not apply without new public API, thus they stay.
    - Other files: `rg` over Tests/FoundationModelsExtrasTests/ModelPool/ and Sources/FoundationModelsExtras/ModelPool/ found no other `.count` compared with zero.
  timestamp: 2026-09-26T21:00:10.344950+00:00
- actor: claude-code
  id: 01m3fr9e8m3j7s7pbx0arjmc1b
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift. `swift build --build-tests`: 0 warnings, 0 errors. `swift test --filter 'GenerationQueue|ModelRef|ModelCallMark'`: 26 tests in 5 suites passed. Not committed.
    - next: /review
  timestamp: 2026-09-26T21:00:12.436620+00:00
- actor: claude-code
  id: 01m3frmeq1hkjphywbxf6e1qwh
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a7f4051). 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. The prior finding is checked.
    - next: none. The task is in done.
  timestamp: 2026-09-26T21:06:13.345160+00:00
- actor: claude-code
  id: 01m3frmp9ht8gn4vzy25ms19bd
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — 1 file (flag isSet in place of a count compare)
    - test: green — swift test, 473 passed, 0 warnings, 0 skipped
    - commit: a7f4051
    - review: clean — task is done. Commits of this task, in order: d682e45, 919caac, a7f4051. The router pins a7f4051.
  timestamp: 2026-09-26T21:06:21.105900+00:00
position_column: done
position_ordinal: ba80
title: 'ModelPool: move the work queue from the router into the core target'
---
## Why
Decision (user, 2026-09-26): Extras owns one process-wide model pool, a work queue for each model, and a mailbox. FoundationModelsRouter and FoundationModelsMetadataRegistry use it. In one process, each model loads one time only, and all users share it. This task moves the work queue code from the router to the core `FoundationModelsExtras` target.

Correction (user, 2026-09-26): do not add a new library product or a new target. All the pool code goes into the core target. Users import `FoundationModelsExtras`.

## What to do
1. Make the folder `Sources/FoundationModelsExtras/ModelPool/`. Do not change `Package.swift`: no new product, no new target, no new test target.
2. Copy these files from `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/` to the new folder:
   - `Core/ModelRef.swift` (`repo@revision`).
   - `Concurrency/AsyncSemaphore.swift`.
   - `Concurrency/GenerationQueue.swift`, `GenerationWorker.swift`, `GenerationQueueError.swift`.
   - `Session/GenerationReentry.swift` (`ModelCallMark`, `SubmissionTarget`).
   - `Concurrency/RaceGate.swift`. Also copy `SerialAsyncChain.swift` and `CancellableWait.swift` if the files above use them.
3. Copy the router tests for these types to the existing `FoundationModelsExtrasTests` target (for example in `Tests/FoundationModelsExtrasTests/ModelPool/`).
4. Make the API public. This includes the `onQueued` overload of `submit`, because the router uses it.
5. Keep each comment that tells why a construct is necessary. Do not simplify the cancellation code. The queue must continue to refuse a submission that waits inside an open submission on the same queue (this prevents a deadlock).
6. The code must use only Foundation, `Synchronization` and the ULID package. The core target has these already. Do not add MLX or a new dependency.
7. Record the decision in `plan.md` §5 (Rules): the pool, the work queue and the Mailbox are in the core target, and the dependency budget does not change. Record the router and the metadata registry as consumers in §6 (Known consumers). Do not add a new pillar that describes a separate target.

Added (coordinator, 2026-09-26): add the work queue (`GenerationQueue`, the re-entry guard, `onQueued`) to `README.md`, with the purpose and a short example. Do not add a type with the name `ModelPool`: the router pins this commit, and the router has its own public `ModelPool`.

## Acceptance criteria
- [x] `swift build` and `swift test` pass.
- [x] All copied router tests pass in `FoundationModelsExtrasTests`.
- [x] `Package.swift` has no new product, target or dependency.
- [x] `plan.md` §5 and §6 record the decision of 2026-09-26.
- [x] `README.md` has the work queue section with an example.
- [x] No type has the name `ModelPool`.

## Notes
The router depends on Extras by git URL. The router tasks cannot start until this work is pushed.

## Review Findings (2026-09-26 15:51)

> Scope: `review sha HEAD~2..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `plan.md` — no validator matches this file

- [x] `Tests/FoundationModelsExtrasTests/ModelPool/GenerationQueueWorkerTests.swift:360` `code-hygiene/idioms-swift` — isEmpty: Prefer isEmpty over comparing count against zero.
