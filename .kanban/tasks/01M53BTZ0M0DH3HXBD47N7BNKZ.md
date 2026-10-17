---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54mbyfx1e8c73vk71g21sqe
  text: |-
    Research done. Discoveries:
    - The queue records its depth in Job.init (QueueTelemetry.enqueued), BEFORE the enqueue lock. Thus the depth record is not in the same step as the enqueue. For the isTurn order waits (GenerationQueue submit(turn:), PooledEmbedder embedInTurns), the window can reorder jobs. The public `submit(onQueued:)` callback comes after the enqueue and is exact.
    - The footprint stream keeps an evicting key until the evict call returns. Thus waitForEviction parks in its footprint loop, not in `pool.admit {}`. The B6 design as written hangs with correct code.
    - The PooledEmbedder speedup test measures a ratio with ContinuousClock. The design does not name it.
    - With grace 0, BackgroundToolRunner answers with the pending envelope at once, and the run body starts only after the envelope event (kind progress, detail = rendered envelope) is posted to the sink.
    - TelemetryTestSupport is already a dependency of IntegrationTests. `@testable import FoundationModelsExtras` works there.
    - The three models are in the local Hugging Face cache.
    Questions Q1 (B5 metric), Q2 (B6 order), Q3 (speedup clock) went to the coordinator. Work continues on the items that they do not affect.
  timestamp: 2026-10-17T09:51:25.181875+00:00
- actor: claude-code
  id: 01m54mdb63jg4rmfqjdcqp2nwq
  text: |-
    Decisions from the peer session for Q1-Q3:
    - Q1: (a) plus (c). Accept no window anywhere. (c): the queue records the depth increment in enqueue(_:resume:), inside the lock of the count, after the yield of the job. Job.init still makes the ticket (the enqueue instant and the factory), but it does not increment. A job that is refused before the yield gets no increment and no decrement. A new unit test shows that a job that is cancelled before the enqueue leaves the depth at 0, and that the test fails on the old code. The GenerationQueue integration tests use submit(onQueued:) and a latch in the job body. The PooledEmbedder FIFO test and the unit helper startQueuedCall use the depth metric. Support/Waiting.swift goes. The Sources change goes in its own fix(...) commit.
    - Q2: (a). waitForEviction first runs `pool.admit {}`, then the footprint loop. The fault demo removes both waits. A demo that removes only `pool.admit {}` is not used: the footprint loop is then a correct wait with no event that the test can see, thus the test hangs and does not fail.
    - Q3: assert the cause, not the speed. Through a TelemetryCapture, the test asserts that the mixed-length call pads fewer tokens than one padded batch of the same texts, from the sub-batch telemetry. The ContinuousClock reads of the speedup test go. If the padding counts are not available on that path, stop that item and report.
  timestamp: 2026-10-17T09:52:10.947162+00:00
- actor: claude-code
  id: 01m54pvssftfy0f9kq7h506yzf
  text: |-
    Implementation landed (local commits, not pushed): e87e88f, caae75b, 774663a, a39be2c, 8666a30, bc32894, 314bf40, 11dc8f5.
    What was shown to fail on wrong code:
    - Depth unit test (cancelled before the enqueue): fails on the old queue with depth [1.0, 0.0].
    - Eviction wait: with both waits removed from waitForEviction, the test fails ("Expectation failed: evictionEndedAtReturn"). Removing only `pool.admit {}` is not a demo: the footprint loop then is a correct wait with no event that the test can see, thus the test hangs and does not fail.
    - B10 first run: the MLX stream gives partial snapshots ("1\n2\n3\n4\n5" at the cancel), but a cancel ends the stream with no error. Generation.stream now calls Task.checkCancellation() after the loop, so a cancelled job gives CancellationError as respond does.
    Discoveries:
    - Each copy of the metallib in the xctest bundle breaks the code sign of the next build. Remove the copies before a build, and copy them after it (CI copies after the build).
    - The settlement observer wait has no failure event: the run plane gives the terminal to the observer after it settles the run.
    - The stuck-tool test and the reentry test have no failure event for a call that waits for ever; reentry now uses onQueued as the failure event.
    IntegrationTests counts, before/after: .timeLimit 9 -> 0, Task.sleep 6 -> 0, ContinuousClock 25 -> 0, poll loop 1 (8 uses) -> 0.
    IntegrationTests full run: 43 tests in 10 suites passed, 0 failed, 0 skipped.
  timestamp: 2026-10-17T10:35:01.807366+00:00
- actor: claude-code
  id: 01m54q6gk1k3pnbcvndgrbx8ta
  text: |-
    ### implement — changed
    - evidence: commits e87e88f, caae75b, 774663a, a39be2c, 8666a30, bc32894, 314bf40, 11dc8f5 (local, not pushed). `swift test --package-path IntegrationTests` (after the metallib copy): 43 tests in 10 suites passed. Root `swift test`: 1223 tests in 120 suites passed (and the other test-run lines of 131, 40, 44, 26 and 410 tests passed); the only warning is the known Cmlx "missing creator" warning.
    - next: /review. The Tests/ items of the first list of the description are out of the scope of this pass.
  timestamp: 2026-10-17T10:40:52.833309+00:00
- actor: claude-code
  id: 01m54rv86pv81ek5ehw1sgjqds
  text: |-
    Tests/ pass picked up. Scope from the coordinator: the named list, plus A (each real-clock `wait(seconds:)` settle limit in Tests/), plus D (the ContinuousClock reads in SerialAsyncChainTests and GenerationQueueWorkerTests, and the ContinuousClock() default of MarketplaceStoreFixture). B (real mount timeouts that elapse) and C (real 30 s settle graces) are not in this pass; the coordinator adds a card for them.
    Discoveries:
    - RunPlane.wait already reads the injected clock (RunPlane(clock:)). No Sources change is necessary for it.
    - QueueTelemetry read ContinuousClock directly. It now takes an internal `now` closure (default ContinuousClock.now). No public API changes.
    - A new test helper ManualRunClock.elapse(_:endingWait:) moves the clock to one step before the timer, checks that the timer still waits, then moves the last step and checks that the timer ended. Thus a timer that is early, late or missing fails, and the test does not hang.
    - The grandchild exit test had no failure event without its kevent deadline. The grandchild now writes a marker file only when its sleep ends by itself; the test waits for the exit with no deadline and expects no marker.
  timestamp: 2026-10-17T11:09:40.950445+00:00
- actor: claude-code
  id: 01m54scebsbjyqaqj0krkqcq8v
  text: |-
    Tests/ pass landed (local commits, not pushed): 880a830 fix(telemetry), 0416187, 5a749f1, 960877a, 5f4b8c2, 7d52fd1.
    Fault demos (each wrong program applied to Sources, the changed tests run one time, then `git checkout -- Sources`):
    - Run 1, 6 tests, all failed in 0.002 s, no hang:
      - deadline twice as long in RunPlane.addWaiter: waitDeadlineElapses and waitReportsTheDeadlineElapsing fail at "the timer did not end" (sleeperCount == 0).
      - settle wait removed in BackgroundToolRunner (wait seconds 0): runStillGoingWhenTheGraceElapsesAnswersPending fails at "the task set no timer" (sleeperCount == 1); aBackgroundRunThatContinuesTimesTheStartAndTheSettleWait fails at the "span still open" and "timer still open" checks and at sleeperCount == 1.
      - QueueTelemetry start instant set to the enqueue instant: aLaterDeliveryWaitsForTheHeldDelivery and theSecondJobWaitsAtLeastTheRunTimeOfTheFirst fail at their wait-time checks.
    - Run 2, 15 tests, 11 issues, ended after 60 s (the 60 s is the real sleep of the grandchild fixture):
      - deadline half as long: both deadline tests fail at "the timer ended before" (sleeperCount == 1).
      - run plane resumes each settle waiter with .cancelled: tests that use MountFixtures.settledTerminal, the DeclaredRunKindTests settledTerminal helper, ToolContextTests waitResolvesToTheTerminalEvent and RunPlaneActorTests startListingAndWaitLifecycle fail at their settledTerminal requirement in 0.002 s.
      - kill() of the child in place of killpg(): aChildOfTheChildIsAlsoKilledBecauseTheKillGoesToTheGroup fails at "no marker" after the 60 s sleep of the grandchild ends.
      - inverted wildmatch result: pathologicalStarPatternDoesNotBlowUp fails at its result check. A blow-up has no event: the test then does not end.
    - Not reached by a fault: OperationMountTests and aBackgroundMountPostsAfterTheCallReturned (their runs settle before the wait, thus the wait returns from the settled list) and the cleanup waits whose result no test reads. Only their time limit was removed; no assertion changed.
    Counts in Tests/ (before -> after): ContinuousClock 9 -> 0; settle time limits (settlementDeadline, collectSeconds, real-clock `seconds: 5`) 36 -> 0 (RunClockTests keeps one `seconds: 5` on a ManualRunClock, which is the deadline under test); kevent timespec 1 -> 0; the Date() clock read of WildmatchTests 1 -> 0. Four `Date()` stay in ToolCallReportTests and ToolCallReportAndWaitPublicSurfaceTests as report stamps; no test waits on them or measures them.
    Full root `swift test` (one run): 1223 tests in 120 suites passed, and the runs of 410, 131, 44, 40 and 26 tests passed. 0 failures. The only warning is the known Cmlx "missing creator" warning.
  timestamp: 2026-10-17T11:19:04.313830+00:00
- actor: claude-code
  id: 01m54sdqfcczazxdmthdtkgtng
  text: |-
    ### implement — changed
    - evidence: commits 880a830, 0416187, 5a749f1, 960877a, 5f4b8c2, 7d52fd1 (local, not pushed). 1 Sources file (Telemetry/QueueTelemetry.swift, internal init parameter only) and 19 test files. Root `swift test`: 1223 tests in 120 suites passed, plus the runs of 410, 131, 44, 40 and 26 tests; 0 failures; only the known Cmlx warning.
    - next: /review. B and C (real mount timeouts and real settle graces in Tests/) go to the card that the coordinator adds.
  timestamp: 2026-10-17T11:19:46.412311+00:00
- actor: claude-code
  id: 01m54smcaxc6ndjpqm7zgpsmrb
  text: 'What stays: ProcessRunnerTests theDurationCoversTheWholeRun (ProcessRunnerTests.swift:190-195). The child sleep is real time, thus a manual clock cannot replace it. The test has only a lower bound (duration >= the child sleep). A lower bound cannot fail on a slow runner. It has no upper bound and no ratio. No change is necessary.'
  timestamp: 2026-10-17T11:23:24.381036+00:00
position_column: done
position_ordinal: ffa580
title: 'Tests: remove the clock reads, sleeps and time limits that stay in Tests/ and IntegrationTests/'
---
Found during ^k2k3b03. These places still read a clock, sleep, poll or set a time limit in a test. Each must end on the event that it expects, or on a failure event.

- IntegrationTests: `.timeLimit` on 8 suites (MLXModelLoader, PooledEmbedder, EvictionWait, ModelPool, PooledModel, ModelPoolSmoke, GenerationQueue, ToolHosting) and the comment in Support/RealModelSuites.swift.
- IntegrationTests: `Task.sleep` in ToolHostingFixtures.swift (3), EvictionWaitTests.swift, GenerationQueueIntegrationTests.swift, and the poll loop in Support/Waiting.swift.
- IntegrationTests: `ContinuousClock` reads in PooledEmbedderIntegrationTests, ModelPoolIntegrationTests, GenerationQueueIntegrationTests, ToolHostingIntegrationTests and Support/RecordingLoader.swift.
- Tests: `ContinuousClock` reads in SerialAsyncChainTests, GenerationQueueWorkerTests, BackgroundToolRunnerTests and ToolContextMountTests (elapsed time checks), and the `ContinuousClock()` default in Tests/MarketplaceFixtures/MarketplaceStoreFixture.swift.

Decide for each place if it is a wait (remove it) or a measure that a test asserts on (replace it with an event or a fake clock).

## Approved design (scope of this pass: IntegrationTests/ only)

Goal: no .timeLimit, no Task.sleep, no poll loop, no retry, no deadline, no ContinuousClock read in IntegrationTests. Each wait ends on its event or on a failure event. Work that must take time is held by a gate that the test opens. Library behavior that uses the real clock stays. No CI change. No public API change in Sources.

- [x] A1. Remove each `.timeLimit` and `RealModelSuites.testTimeLimitMinutes`; fix its doc (a hung run stops making output; the watcher cancels it; the last log lines name the stuck test).
- [x] A2/A3. Each wait ends on its event or a failure event. An MLX hang or a stalled download has no event; that is accepted.
- [x] B5. Delete Support/Waiting.swift. Recorder conditions use an awaitable recorder with waitUntil. `queue.isRunning` uses a latch that the job body opens. Decision Q1: (a) plus (c). The queue records the depth increment inside the enqueue lock (internal Sources fix). The GenerationQueue tests use submit(onQueued:) and a job latch; the PooledEmbedder FIFO test and startQueuedCall use the depth metric.
- [x] B6. EvictionGate gets a "started" latch. The gate opens on the first of "the admission queue holds a second job" (depth 2) or "waitForEviction returned". Then expect the evict call had returned. Decision Q2: waitForEviction runs `pool.admit {}` first, then the footprint loop. The fault demo removes both waits.
- [x] B7. ArchiveScanTool body waits on a gate. A watcher opens it when the call posted its pending envelope.
- [x] B8. EndlessScanTool waits on a latch that a cancellation handler opens, then throws CancellationError.
- [x] B9. StuckRecordTool: the detached task waits on a test gate that the test opens after its expectations. The duration check becomes "the call returned while the gate was still closed".
- [x] B10. cancelledRunningGenerationStopsEarly: stream the response, signal after the first K snapshots, cancel, expect CancellationError, a generated amount far below the limit, and that the next job runs.
- [x] B11. Replace ContinuousClock timestamps that prove order or overlap with ordered event logs. "Fast" (refusalDelay) becomes "refused before the job ran". Decision Q3: the speedup test asserts the padded tokens of the sub-batches from the span counts.

## Second pass: Tests/

Scope from the coordinator: the named places, plus A (each real-clock settle limit of a run-plane wait in Tests/), plus D (the ContinuousClock reads of SerialAsyncChainTests and GenerationQueueWorkerTests, and the ContinuousClock() default of MarketplaceStoreFixture). B (real mount timeouts that elapse) and C (real settle graces on a real-clock run plane) are not in this pass; the coordinator adds a card for them.

- [x] T1. RunPlane wait deadlines: the tests give RunPlane(clock:) a ManualRunClock (RunPlane.wait already reads that clock). MountFixtures.settledTerminal, ToolContextTests, ToolContextMountSinkPublicSurfaceTests, DeclaredRunKindTests, OperationMountTests, RunPlaneTests and ToolHostingReadmeTests wait for the settlement with no deadline. RunPlaneActorTests waitDeadlineElapses and ToolContextTests waitReportsTheDeadlineElapsing use ManualRunClock.elapse(_:endingWait:).
- [x] T2. BackgroundToolRunnerTests and ToolCallSpanTests: the settle period runs on a manual clock; no real-time measure.
- [x] T3. WildmatchTests: no Date() read.
- [x] T4. ProcessRunnerTests: no kevent deadline; the grandchild writes a marker only when its sleep ends by itself.
- [x] T5. QueueTelemetry takes an internal `now` closure; SerialAsyncChainTests and GenerationQueueWorkerTests move a manual clock.
- [x] T6. MarketplaceStoreFixture uses a ManualClock when the test gives no clock.