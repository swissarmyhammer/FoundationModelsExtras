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
position_column: doing
position_ordinal: '80'
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

The Tests/ items of the first list are not in the scope of this pass.