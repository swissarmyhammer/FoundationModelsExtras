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
- actor: claude-code
  id: 01m3fw5k1sn34r4xndvvn1bkr9
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (a255ea4). 1 finding (1 confirmed, 0 refuted): Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:112 swift/value-semantics. No finding asks for a lock, semaphore, actor or router-style complexity, so no conflict with the user decision on the pool tasks.
    - next: change `final class FakeEmbedding` to `struct FakeEmbedding`, and remove the same cause from all of ModelPoolTestSupport.swift. Then run the review again.
  timestamp: 2026-09-26T22:08:00.569560+00:00
- actor: claude-code
  id: 01m3fw5vqfag7vk8821z03nswc
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — ModelPool.swift, PooledEmbedder.swift, 8 tests, test support, README
    - test: green — swift test, 493 passed, 0 warnings, 0 skipped
    - commit: a255ea4
    - review: findings — Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:112
  timestamp: 2026-09-26T22:08:09.455460+00:00
- actor: claude-code
  id: 01m3fw7zzfww3yyg95g8dtf6vm
  text: 'Research for the finding ModelPoolTestSupport.swift:112 swift/value-semantics. FakeEmbedding and RecordingLoader are classes only because each keeps a `Mutex<Int>` call counter. A struct cannot keep a `Mutex` field and stay Copyable, and `PooledEmbedding` and `PooledModelLoader` require Copyable (a loader or a container goes into `any Sendable`). Plan: add one `final class Counter` (a shared `Mutex<Int>` that tasks increment, so it needs reference semantics), and make FakeEmbedding and RecordingLoader structs that keep a `Counter`. Copies of a struct share the same Counter and the same Recorder, so the behavior does not change. This also removes the two copies of the same increment block. Classes that stay: FakeModel (tests compare two models with `===`, so it needs identity); Recorder (tasks share it and append to it, so it needs shared mutable state); Counter (tasks share it and increment it). FixedLoader is already a struct.'
  timestamp: 2026-09-26T22:09:19.343370+00:00
- actor: claude-code
  id: 01m3fww1m0kshdeheafsznys8y
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift. FakeEmbedding is now a struct. RecordingLoader is now a struct (same cause: its only reason to be a class was a `Mutex<Int>` load counter). New `final class Counter` keeps the shared call count; FakeEmbedding and RecordingLoader each keep one, and the two copies of the increment block are gone. Classes that stay, and why: FakeModel — tests compare two models with `===` (identity); Recorder — tasks share one log and append to it (shared mutable state); Counter — copies of a fake share one count and tasks increment it (shared mutable state). FixedLoader was already a struct. The finding is marked `- [x]`. `swift build`: Build complete, 0 warnings. `swift test --filter 'ModelPool|PooledEmbedder'`: 20 tests in 2 suites passed, 0 warnings. No commit, no push.
    - next: /review
  timestamp: 2026-09-26T22:20:16.384878+00:00
- actor: claude-code
  id: 01m3fxp7y929qqq5nd9cqcqtky
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (00dbc07): 0 findings, 0 confirmed, 0 refuted. 1 file reviewed. The prior finding is checked.
    - next: none. The task is in done.
  timestamp: 2026-09-26T22:34:34.825110+00:00
- actor: claude-code
  id: 01m3fxpnm422a61nbmvvdmd5ke
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (test fakes as structs with a shared Counter)
    - test: green — swift test, 493 passed, 0 warnings, 0 skipped
    - commit: 00dbc07
    - review: clean — task is done. Commits of this task, in order: a255ea4, 00dbc07. The router pins 00dbc07.
  timestamp: 2026-09-26T22:34:48.836919+00:00
depends_on:
- 01M3FN95AM98RJSTCVQ8G1Z7KE
position_column: done
position_ordinal: bc80
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

## Review Findings (2026-09-26 17:03)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift:112` `swift/value-semantics` — Use struct, not class. FakeEmbedding does not need identity semantics or reference behavior. Change `final class FakeEmbedding` to `struct FakeEmbedding`.
