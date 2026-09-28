---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3kxwmr67d2d8vtxabkksqf7
  text: 'Research: ModelPool.swift has 6 yield sites under the state Mutex: footprints (first value), holdIfResident, load, setLoadingBytes, release, evictIfIdle (all through State.publish, footprints yields directly). onTermination takes the state Mutex. Plan: add a second Mutex (the publish lock). Each publishing change takes the publish lock, then the state lock to change the state, read the footprint and copy the continuations; it releases the state lock and yields under the publish lock. onTermination takes only the state lock. No code takes the publish lock under the state lock, and no code yields under the state lock. Thus the order of the values is the order of the changes, with no skipped value, and a new stream registers and gets its first value in one publish-lock step. The release still enqueues the eviction job in the same state-lock step. Tests go in ModelPoolTests.swift, which has the private helpers first(_:of:) and BoundedWait.'
  timestamp: 2026-09-28T11:55:02.278644+00:00
- actor: claude-code
  id: 01m3kywakg6bjq2pp78zx4d6ef
  text: 'RED: the stress test reproduces the deadlock. A `sample` shows swift_task_cancelImpl -> AsyncStream._Storage.cancel -> onTermination of footprints waiting on the pool lock, and the other stress threads waiting in footprints.getter. Dead end: with the stress tasks on the cooperative pool, the deadlock blocked every cooperative thread, so BoundedWait never ran and the test hung (timeout 124, and orphan swiftpm-testing-helper processes stayed; kill them after a timed-out run). Fix in the test: the stress tasks run on a DedicatedTaskExecutor (a TaskExecutor on its own concurrent DispatchQueue, in ModelPoolTestSupport.swift), so the deadlock blocks only those threads and the bounded wait fails the test in 5 s. With the old code, the two stress tests fail at the bound and the order test passes.'
  timestamp: 2026-09-28T12:12:20.464389+00:00
- actor: claude-code
  id: 01m3kzm3xeev3wp7vxc58yj9hz
  text: 'Implementation landed. ModelPool.swift: a second Mutex `publishing` (the publish lock). `publish(_:)` takes the publish lock, then the state lock to run the step (change the state, read the footprint, copy the streams to yield to); it releases the state lock and yields under the publish lock only. `publishToEachStream(_:)` wraps it for all live streams. State.publish() is gone. All six sites use it: footprints (registers the stream and yields its first value in one publish step, so no later change comes first), holdIfResident (no yield when the key is not resident), load, setLoadingBytes (load and failed load), release (the eviction enqueue stays in the same state-lock step, lock order publish -> state -> queue), evictIfIdle. onTermination takes only the state lock. No code takes the publish lock under the state lock. GenerationQueue is not changed. I chose the publish lock around the state step, not sequence numbers, because a sequence scheme that skips an older value would lose a change, and the card keeps "each change in order". Tests: 3 new tests in ModelPoolTests.swift; DedicatedTaskExecutor in ModelPoolTestSupport.swift. Note: every SwiftPM run prints "failed loading/storing cached manifest ... disk I/O error" warnings; they come from the SwiftPM manifest cache of this machine, not from the code.'
  timestamp: 2026-09-28T12:25:20.046391+00:00
- actor: claude-code
  id: 01m3kzm7qjzghhga84zpdxzh6w
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/ModelPool/ModelPool.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift. `swift build --build-tests` OK with no code warnings. `swift test --filter 'FoundationModelsExtrasTests\.ModelPoolTests/(streamsThatCancelBesideEvictionsDoNotDeadlock|aLiveStreamSeesTheLastFootprintAfterTheStress|oneStreamSeesTwoQuickReleasesInOrder)'`: 3 tests ran, 3 passed, 20 of 20 runs (before the fix: the 2 stress tests failed at the 5 s bound). `swift test --parallel --num-workers 8` 10 times in sequence: 10 of 10 passed, exit 0, 1380 tests passed in each run (6 Swift Testing runs), 0 failures, no hang.
    - next: /review
  timestamp: 2026-09-28T12:25:23.954702+00:00
position_column: doing
position_ordinal: '80'
title: Fix the lock-order deadlock between ModelPool.publish and the onTermination of footprints
---
## Problem

The FoundationModelsRouter full test suite hangs. A `sample` of the hung process shows a lock-order inversion in `ModelPool` (Sources/FoundationModelsExtras/ModelPool/ModelPool.swift):

- Thread A: `Router.deinit` -> `PromptCacheSizing.deinit` -> `footprintsTask.cancel()` -> `swift_task_cancelImpl` holds the status lock of the task that reads `footprints` -> `AsyncStream._Storage.cancel` -> the `onTermination` closure of `footprints` (line 88) -> waits for the pool `Mutex`.
- Thread B: the eviction job (`release` -> `evictIfIdle`) -> `state.withLock { $0.publish() }` holds the pool `Mutex` -> `AsyncStream._Storage.yield` -> `UnsafeContinuation.resume` -> waits for the status lock that thread A holds.

Thus `publish` yields while it holds the pool `Mutex`, and `onTermination` takes the pool `Mutex` while the runtime holds the status lock of the consumer task. Fix c7691c0 makes evictions run sooner, so the problem occurs more frequently.

## Requirement (decided design)

- The pool must never call `continuation.yield` or `finish` while it holds a lock that `onTermination` takes.
- `onTermination` must never take a lock that a yield can hold.
- Examine each `publish` call site: `footprints` (the first value), `holdIfResident`, `load`, `setLoadingBytes` (loads and failed loads), `release`, `evictIfIdle`.
- Approach: under the state `Mutex`, compute the new footprint and copy the live continuations. Yield outside the state `Mutex`. Use a separate publish-order step so that two publishes cannot deliver values out of order (for example, a publish sequence number and a separate delivery lock that `onTermination` never takes; or a delivery step that sends only the newest value). `onTermination` removes its continuation with a step that can never wait for a yield (it takes only the state `Mutex`, and no code yields under the state `Mutex`).
- Keep these behaviors:
  - Each stream gets the current value first, then each change in order.
  - The admission FIFO.
  - The synchronous release and the eviction order from c7691c0 (the last release puts the eviction job in the admission queue in the same lock step).
  - Fix bc47b26 (the queue does not keep a job result after it resumes the caller).

## Tests (Tests/FoundationModelsExtrasTests)

- Stress test: many consumers start and cancel `footprints` streams in a loop, while other tasks acquire and release holds, so that evictions run. The test must end with no hang. Wait on a real signal with a time limit (not a wall-clock sleep), so that a hang fails the test and does not stop the suite.
- After the stress, a live consumer sees the last footprint.
- Order: one consumer sees the values of two quick publishes in the order that they occurred.

## Acceptance criteria

- The new tests pass.
- `swift test --parallel --num-workers 8` passes 10 times in sequence with no hang.
- When you use `swift test --filter`, check the count of tests that ran. A filter with a display name matches no test and exits 0.
- Do not run `swift format`.
- Do not push. The user must approve the push.

## Source

Request from the FoundationModelsRouter session (foundationmodelsrouter-e0). Its batch of work waits for this fix.