---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hm2thd53386bkwphhzy73p
  text: |-
    Research done. Findings:
    - PooledEmbedder keeps one ModelHold and submits each embed(texts:) as one job in hold.queue. All holds of one key share one GenerationQueue (the entry queue), thus two users of one embedding key share one queue.
    - The first loader of a key wins. A later acquire with a different loader gets the first container and its loader is not called.
    - MLXPooledLoader gives a private MLXEmbedding (a struct), thus a test cannot compare containers by identity. The tests use the shared queue (===) and the load records of RecordingLoader as the evidence of one entry.
    - To see the order of the embed jobs, the FIFO test uses a loader that wraps the MLX embedding in a PooledEmbedding that records each call (texts, start, end). The first loader wins, thus both users get the recording container.
    - The FIFO test submits a first queue job that runs until all embed calls wait (Waiting.until on queue.waitingCount), and puts the embed calls in the queue in turns, as GenerationQueueIntegrationTests does. No lock, semaphore or gate type.
    - Plan: one new file IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift, a nested suite of RealModelSuites with .timeLimit.
  timestamp: 2026-09-27T14:25:10.189157+00:00
- actor: claude-code
  id: 01m3hmwqzt5wecak3xn8ehgtn8
  text: |-
    BLOCKER: the real-model FIFO test shows a defect in GenerationQueue (Sources/FoundationModelsExtras/ModelPool/GenerationQueue.swift, submit(isolation:onQueued:_:)).

    Defect: submit counts a job before it puts the job in the FIFO. `job.wait(continuation)` adds 1 to `unfinished` (thus `waitingCount` shows the job as waiting), and after that a separate `jobs.yield(job)` puts the job in the stream. The two steps are not one atomic step. A different task can see the job as waiting, submit its own job, and its job goes into the stream first. Thus a job that `waitingCount` shows as waiting can be passed by a job that was submitted later. FIFO order and the observable waiting count do not agree.

    Evidence (2nd full run of `swift test --package-path IntegrationTests`, test "concurrent embed calls of two users run one at a time, first in first out, and each gives the vectors of a serial run", PooledEmbedderIntegrationTests.swift:110):
    - expected run order: [Summarize the open pull requests.], [A tool that lists the files of a folder.], [Write a unit test for the parser.], [A tool that runs a shell command.], [Explain the last build failure.], [A tool that searches the code for a symbol.]
    - real run order: calls 0, 1, 2, 4, 5, 3 (call 3, "A tool that runs a shell command.", ran last).
    - Call 4 goes into the queue only when `isRunning && waitingCount == 4`. A first job runs and calls 0, 1, 2 wait, thus the count is 3 until call 3 adds itself. So call 3 was counted before call 4 submitted, but call 4 and call 5 ran before call 3. The first job holds the queue until 6 calls wait, so all 6 calls waited behind it.
    - The rate is low: 20 repetitions of this test alone passed (`--filter concurrentEmbedsRunOneAtATimeInOrder --maximum-repetitions 20 --repeat-until fail`). The failure came in 1 of 2 full runs.
    - The same assumption (waitingCount == n means the job is in the queue) is in GenerationQueueIntegrationTests.submit(turn:), GenerationQueueWorkerTests.submitWaiting and PooledEmbedderTests.waitForQueuedCalls. Those tests have the same latent race.

    Decision for a person:
    (a) Correct GenerationQueue so that the count and the yield are one atomic step (for example, a queue-level lock around the increment and `jobs.yield`), then run this task again; or
    (b) Accept that `waitingCount` is not a queue position, and change the FIFO tests to get the entry order in a different way.
    I did not change the Extras code and I did not weaken the test.

    Other results: the root `swift test` passed (726 tests in 69 suites, 1m48.9s). Integration run 1 passed (14 tests in 5 suites, 1m39.1s). Integration run 2 failed with the 1 issue above (1m30.8s). The run of the new suite alone passed (5 tests, 1m13.3s). The other 4 new tests passed in each run.
  timestamp: 2026-09-27T14:39:19.546497+00:00
- actor: claude-code
  id: 01m3hmwwn9rcfk5e9v3jn50epe
  text: |-
    ### implement — stuck
    - evidence: 1 file added — IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift (5 tests, one for each item of "Tests to add"). `swift test` (root): 726 tests passed, 1m48.9s. `swift test --package-path IntegrationTests`: run 1 passed, 14 tests, 1m39.1s; run 2 failed, 1 issue at PooledEmbedderIntegrationTests.swift:110 (FIFO order 0,1,2,4,5,3), 1m30.8s. Acceptance criterion "3 runs in a row" is not met.
    - next: a person decides between (a) correct GenerationQueue.submit so that the count and the yield are one atomic step, or (b) change the FIFO tests. See the BLOCKER comment.
  timestamp: 2026-09-27T14:39:24.329514+00:00
- actor: claude-code
  id: 01m3hmzja8veqm9s0d106h6y1f
  text: |-
    ### decision — fix the library, keep the tests
    - The FIFO test is correct. The order 0,1,2,4,5,3 is a real defect in `GenerationQueue.submit`: the count and the yield are two steps.
    - Task ^38ybj4j fixes the queue. After it is done, run the 5 tests in PooledEmbedderIntegrationTests.swift 3 times in a row, then commit.
  timestamp: 2026-09-27T14:40:52.040278+00:00
depends_on:
- 01M3HD6T6P13MA52XSVQ8EEGJF
position_column: doing
position_ordinal: '80'
title: 'Integration tests 3: real-model tests of PooledEmbedder, shared by two users'
---
## Why
The metadata registry and the router will share one embedding model through `PooledEmbedder`. The unit tests use a fake embedding. These tests use a real MLX embedding model in the nested `IntegrationTests/` package.

## Tests to add
- [ ] A real embed: `PooledEmbedder` from a real `.embedding` hold gives vectors of `dimension` length, and two similar texts are closer (cosine) than two unrelated texts.
- [ ] Two users, one model: a "router" loader and a "registry" loader both acquire the same embedding key; the model loads one time; the second user gets the first loader's container and embeds through `PooledEmbedding` with correct results.
- [ ] One embed at a time: many concurrent `embed(texts:)` calls from both users run one at a time on the entry's queue, in FIFO order, and every call gets the correct vectors (compare with a single serial run).
- [ ] An embedder handle keeps the model resident: the model is not evicted while a `PooledEmbedder` exists, and it is evicted after the last handle goes away.
- [ ] An LLM and an embedding model resident at the same time: each has its own queue, so an embed does not wait behind a long generation.
- Give each test a time limit. Simple test code; no lock/semaphore/gate types.

## Acceptance criteria
- [ ] `swift test --package-path IntegrationTests` passes on this machine, 3 runs in a row.
- [ ] The root `swift test` is unchanged and passes.

#integration-tests