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
position_column: doing
position_ordinal: '80'
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