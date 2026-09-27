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
- actor: claude-code
  id: 01m3hp8kwf0wpt7tx79nmmwg4g
  text: |-
    ### test — green
    - evidence: `swift test --package-path IntegrationTests`, 3 runs in a row, each 14 tests in 5 suites, 0 failures. Run 1: 51.459s. Run 2: 45.764s. Run 3: 55.274s. Each run had only the accepted warning ("missing creator for mutated node ... mlx-swift_Cmlx.bundle"). Root `swift build`: clean, no warnings. Root `swift test`: 727 tests in 69 suites passed, 3.635s, no warnings.
    - next: commit the test file and .kanban/, then move the task through review.
  timestamp: 2026-09-27T15:03:17.135179+00:00
- actor: claude-code
  id: 01m3hpeqgnc359r2mdp6x8t1d3
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 2 findings (2 confirmed, 0 refuted) — PooledEmbedderIntegrationTests.swift:211, PooledEmbedderIntegrationTests.swift:294 (code-hygiene/idioms-swift preferLazyMap)
    - next: implement — use lazy.map before min() at each finding, and at all other places in the file with the same cause. Then test, commit and review again.
  timestamp: 2026-09-27T15:06:37.461979+00:00
- actor: claude-code
  id: 01m3hpf0zfvznhkgxxemxfjbjx
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — PooledEmbedderIntegrationTests.swift (5 tests)
    - test: green — IntegrationTests 3 runs, 14 passed each; root 727 passed
    - commit: ba6415b
    - review: findings — PooledEmbedderIntegrationTests.swift:211, PooledEmbedderIntegrationTests.swift:294
  timestamp: 2026-09-27T15:06:47.151647+00:00
- actor: claude-code
  id: 01m3hpkq0w9n7n6ymncxfpvgg0
  text: |-
    ### implement — changed
    - Finding at PooledEmbedderIntegrationTests.swift:211: `stream` is an `AsyncStream`. `AsyncSequence` has no `lazy` property, thus `.lazy.map` does not compile there. The `map` of an `AsyncSequence` is already lazy. To remove the cause (a `map` before a single-pass `reduce`), the `map` step is removed: `stream.reduce(into: [])` now calls `vector(of:with:)` and appends in one closure. A `for` loop with a `var` accumulator is not used, because the swift immutability rule forbids it.
    - Finding at PooledEmbedderIntegrationTests.swift:294: `vector.lazy.map { $0 * $0 }.reduce(0, +)`.
    - Same cause, same file: `cosineSimilarity` now uses `zip(first, second).lazy.map(*).reduce(0, +)`.
    - Other `map` calls in the file feed `==`, an argument, or a return value, not a single-pass operation. No change there. No other file in IntegrationTests/Tests changed in this task.
    - evidence: `swift test --package-path IntegrationTests`: 14 tests in 5 suites passed, 45.641s; only warning is the accepted "missing creator for mutated node ... mlx-swift_Cmlx.bundle".
    - next: review.
  timestamp: 2026-09-27T15:09:20.796718+00:00
- actor: claude-code
  id: 01m3hpq7q8p1xh46v75wrrvpbn
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (b00515c): 0 findings, 0 confirmed, 0 refuted; 7 validator runs, 0 failed. All prior review items are checked.
    - next: none. The task moved to done.
  timestamp: 2026-09-27T15:11:16.200715+00:00
- actor: claude-code
  id: 01m3hpqe9qkbx87z5j6c4rkdhp
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — PooledEmbedderIntegrationTests.swift (lazy.map; reduce on the async stream)
    - test: green — IntegrationTests 14 passed
    - commit: b00515c
    - review: clean — 0 findings; task in done
  timestamp: 2026-09-27T15:11:22.935607+00:00
depends_on:
- 01M3HD6T6P13MA52XSVQ8EEGJF
position_column: done
position_ordinal: c680
title: 'Integration tests 3: real-model tests of PooledEmbedder, shared by two users'
---
## Why
The metadata registry and the router will share one embedding model through `PooledEmbedder`. The unit tests use a fake embedding. These tests use a real MLX embedding model in the nested `IntegrationTests/` package.

## Tests to add
- [x] A real embed: `PooledEmbedder` from a real `.embedding` hold gives vectors of `dimension` length, and two similar texts are closer (cosine) than two unrelated texts.
- [x] Two users, one model: a "router" loader and a "registry" loader both acquire the same embedding key; the model loads one time; the second user gets the first loader's container and embeds through `PooledEmbedding` with correct results.
- [x] One embed at a time: many concurrent `embed(texts:)` calls from both users run one at a time on the entry's queue, in FIFO order, and every call gets the correct vectors (compare with a single serial run).
- [x] An embedder handle keeps the model resident: the model is not evicted while a `PooledEmbedder` exists, and it is evicted after the last handle goes away.
- [x] An LLM and an embedding model resident at the same time: each has its own queue, so an embed does not wait behind a long generation.
- Give each test a time limit. Simple test code; no lock/semaphore/gate types.

## Acceptance criteria
- [x] `swift test --package-path IntegrationTests` passes on this machine, 3 runs in a row.
- [x] The root `swift test` is unchanged and passes.

#integration-tests

## Review Findings (2026-09-27 10:03)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 1 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift:211` `code-hygiene/idioms-swift` — preferLazyMap: Prefer lazy.map over map before single-pass operations like min().
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/PooledEmbedderIntegrationTests.swift:294` `code-hygiene/idioms-swift` — preferLazyMap: Prefer lazy.map over map before single-pass operations like min().
