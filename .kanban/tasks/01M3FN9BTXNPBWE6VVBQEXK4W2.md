---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fvddymm0bbktkkfkmyf34k
  text: 'Research: ModelPool is a final class with one Mutex<State>. Entry has container, loader, bytes, holds. holdIfResident and load make ModelHold. GenerationQueue already has the re-entry guard (refuseWaitInsideOpenSubmission via ModelCallMark), so a hold queue keeps it with no change. Plan: Entry gets `let queue = GenerationQueue()`; ModelHold gets `public let queue`; new file PooledEmbedder.swift holds PooledEmbedding, PooledEmbedder and PooledEmbedderError. Tests go in Tests/FoundationModelsExtrasTests/ModelPool/PooledEmbedderTests.swift, fakes (FakeEmbedding, FixedLoader) in ModelPoolTestSupport.swift. No ARCHITECTURE.md in the repo.'
  timestamp: 2026-09-26T21:54:48.916472+00:00
- actor: claude-code
  id: 01m3fvrdtah1h9jj0wrasmr5t7
  text: |-
    ### implement — changed
    - evidence: ModelPool.swift (+14/-8: Entry gets `let queue = GenerationQueue()` and is fileprivate; ModelHold gets `public let queue` and is made from the entry), new PooledEmbedder.swift (68 lines: PooledEmbedding, PooledEmbedder, PooledEmbedderError), new PooledEmbedderTests.swift (196 lines, 8 tests), ModelPoolTestSupport.swift (+73: FakeEmbedding, FixedLoader), README.md (+27: "One queue for each model: `PooledEmbedder`"). RED seen first: the test build failed on the missing PooledEmbedding type. `swift build`: 0 warnings. `swift test`: 493 tests in 41 suites passed. PooledEmbedderTests ran 10 times, all passed.
    - notes: No new lock, semaphore or gate type. The re-entry guard is unchanged, because each hold queue is a GenerationQueue. The "not evicted" test reads the footprint just after the handle is made: a hold that the handle did not keep releases at once in deinit and drops the session bytes, so the test fails at once with no race.
    - next: /review
  timestamp: 2026-09-26T22:00:49.226108+00:00
depends_on:
- 01M3FN95AM98RJSTCVQ8G1Z7KE
position_column: doing
position_ordinal: '80'
title: 'ModelPool: the pool entry owns the work queue, and an embedder handle runs each embed call through it'
---
## Why
All users of one model must share one work queue. Today the router MLX container creates the `GenerationQueue` (`LiveModelLoader.swift:60`), so the queue is not part of the pool. Also, embeddings do not go through a queue today (`RoutedEmbedder.swift:51`). The metadata registry needs a queued embedder most.

## What to do
All code goes into the core `FoundationModelsExtras` target, in `Sources/FoundationModelsExtras/ModelPool/`. The tests go into the existing `FoundationModelsExtrasTests` target. Use the names of task 01M3FN95AM98RJSTCVQ8G1Z7KE (`ModelPool`, `ModelPoolKey`, `ModelRole`, `PooledModelLoader`, `ModelHold`).
1. Each pool entry creates and owns one `GenerationQueue`. All holds of one key get the same queue.
2. `ModelHold` gives access to the queue of its entry (`public var queue: GenerationQueue`).
3. Add `public protocol PooledEmbedding: Sendable` with `var dimension: Int { get }` and `func embed(texts: [String]) async throws -> [[Float]]`. A loader returns a container that conforms to it for the `.embedding` role.
4. Add a public embedder handle, `public struct PooledEmbedder: Sendable`, for the `.embedding` role. It has `dimension` and `embed(texts:)`. Each `embed(texts:)` call runs through the queue of the entry. The handle keeps the `ModelHold`, so the model stays resident while the handle exists. The handle gets the embed operation from the container through `PooledEmbedding`, never by a cast to the container type of one user. (The first loader of a key wins, so the container can come from the loader of a different user.)
5. If the container of an `.embedding` key does not conform to `PooledEmbedding`, making the handle throws a clear error.
6. Do not add MLX to the core target.
7. Keep the re-entry guard of the queue: a submission that waits inside an open submission on the same queue is refused.
8. Add the embedder handle and the shared queue to `README.md`.

## Acceptance criteria
- [x] Test: two holds of one key get the same queue instance.
- [x] Test: concurrent `embed(texts:)` calls on one key run one at a time, in FIFO order.
- [x] Test: loader A loads an `.embedding` key. Then a caller with loader B acquires the same key, gets the container of loader A, and embeds through `PooledEmbedding` with success.
- [x] Test: the model is not evicted while an embedder handle exists.
- [x] Test: a cancelled embed call does not block the next call in the queue.
- [x] Test: a container that does not conform to `PooledEmbedding` gives the clear error.
- [x] `README.md` describes the embedder handle.
- [x] The public API has doc comments. `swift test` passes.

#model-pool #cross-repo