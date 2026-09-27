---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fpqzq740dzmvbjwwza2bgg
  text: |-
    ### Design change (user, 2026-09-26): no resolve lock in the Extras pool
    `AsyncSemaphore` is not in Extras (task 01M3FN8WD0G0NJ7QAAKSPZ9RW1 removes it). This replaces item 7 ("keep the resolve lock").
    - The pool loads each key one time with the standard actor pattern: `private var loading: [ModelPoolKey: Task<any Sendable, any Error>]`. The first `acquire` of a key makes the load task and stores it. Each other `acquire` of the same key awaits the same task. When the task ends, the entry becomes resident (or, after an error, the key is removed from `loading` and each waiter gets the error).
    - No `withResolveLock` in Extras. The router keeps its own lock for its joint memory fit.
    - Keep the code simple and the doc comments short. The user does not want the router complexity copied.
    - Acceptance adds: two concurrent `acquire` calls on one key run the loader one time (already a criterion), and a failed load gives the error to each waiter and lets a later `acquire` try again.
  timestamp: 2026-09-26T20:33:11.911971+00:00
- actor: claude-code
  id: 01m3fpt1zme4my99zr8kyz3dgs
  text: |-
    ### Design change 2 (2026-09-26): one admission queue for all loads. This REPLACES "Design change: no resolve lock" above.
    The problem: the dictionary of loads in progress stops two loads of one key, but not a memory overrun. Example: (1) the router measures 20 GB resident and decides that a 12 GB model fits in a 32 GB budget; (2) the registry loads a 4 GB embedder; (3) the router loads the 12 GB model. Now 36 GB is resident in a 32 GB budget.

    The design (a work queue, no lock):
    - The pool owns one `GenerationQueue` for admissions. Each change that can make memory larger runs as one job in that queue, one at a time, in FIFO order.
    - `public func admit<T: Sendable>(_ job: @escaping @Sendable (ModelPoolAdmission) async throws -> T) async throws -> T` runs `job` as one admission job. The router puts its measure + `JointFit` + acquire in one job.
    - `ModelPoolAdmission` (a handle that is valid only inside its job) has `residentFootprintBytes` and `acquire(_:footprintBytes:sessionBytes:loader:)`. That `acquire` runs at once: it does not go into the queue again, so a job cannot wait for itself.
    - `ModelPool.acquire(_:footprintBytes:sessionBytes:loader:)` (the registry, the multitool): when the key is resident, it adds a hold at once, with no wait. When the key is not resident, it is `admit { try await $0.acquire(...) }`.
    - Two callers of the same new key: the first job loads the key. The second job finds the key resident and adds a hold. The load dictionary is not necessary. Remove it.
    - A release does not go through the queue. A release can only make memory smaller.
    - No `AsyncSemaphore`, no `withResolveLock`. The router removes its own lock (router task 01M3FNJS6J7KGAJJ5WFEST00WA).

    Acceptance adds:
    - [ ] Test: a plain `acquire` of a new key, started while an `admit` job runs, starts its load only after that job ends.
    - [ ] Test: `acquire` of a resident key returns while an `admit` job runs (no wait).
    - [ ] Test: inside an `admit` job, `admission.acquire` of a new key loads it and does not deadlock.
    - [ ] Test: two concurrent `acquire` calls of one new key run the loader one time.
    - [ ] Test: a failed load gives the error to its caller, and a later `acquire` tries again.
    Keep the code small and the doc comments short.
  timestamp: 2026-09-26T20:34:19.764472+00:00
- actor: claude-code
  id: 01m3frw5878tpe8756xaphscjv
  text: |-
    ### Research (implement)
    - `GenerationQueue` (same folder) has only an async `submit`. It has no call that adds a job and returns at once. Thus `ModelHold.deinit` (sync) submits the eviction job from one detached task. The eviction job checks the hold count again, so the order of that job and of a later job does not change the result.
    - A job that submits to the same `GenerationQueue` waits for itself. This is why `ModelPoolAdmission.acquire` loads at once and does not submit again.
    - Idea 5 (each entry owns a `GenerationQueue`, `ModelHold.queue`) is step 1 and step 2 of task ^qexk4w2. This task does not add a queue with no reader. Task ^qexk4w2 adds it.
    - Footprints are sent under the lock (`AsyncStream.Continuation.yield` does not block and does not call `onTermination`). Thus each stream sees the changes in the correct order.
    - Tests: `@testable import`, so that a test can read `admissions.waitingCount` and know that an eviction job or a second load waits. This makes the race tests deterministic.
  timestamp: 2026-09-26T21:10:25.799248+00:00
- actor: claude-code
  id: 01m3ftjeg5kcyb5ayxnfpm4gq8
  text: |-
    ### Implementation landed
    - `Sources/FoundationModelsExtras/ModelPool/ModelPool.swift` (197 lines: 124 code, 46 comment, 27 blank): `ModelPool` (a final class with one `Mutex<State>`), `ModelPoolAdmission`, `ModelHold`.
    - `Sources/FoundationModelsExtras/ModelPool/ModelPoolKey.swift` (34 lines: 18 code): `ModelRole`, `ModelPoolKey` (with a public `init(ref:role:)`), `PooledModelLoader`, `ModelPoolFootprint` (also `Equatable`).
    - Code lines of the pool: 142. With doc comments and blank lines: 231.
    - Tests: `Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift` (12 tests, one for each acceptance item and the README example) and `ModelPoolTestSupport.swift` (`RecordingLoader`, `Recorder`, `FakeModel`).
    - README: new section "One load for each model: `ModelPool`", and `ModelPool` in the first paragraph.

    ### What did not work, and why
    - A `change { }` helper that always sends the footprint: `holdIfResident` of a key that is not resident then sent a footprint with no change. Each change now calls `state.publish()` under the lock.
    - The first version of the test "an acquire between the last release and the eviction job" awaited the second `acquire` with no bound. With a broken fast path, the whole `swift test` run hung. The acquire now runs in a task, and the test waits inside `BoundedWait`.

    ### Proof that the tests can fail (mutations, each reverted)
    - No resident check in `ModelPool.acquire`: 2 tests fail (the resident acquire and the acquire before the eviction job).
    - No hold-count check in the eviction job: the test of the acquire before the eviction job fails.
    - No resident check in `ModelPoolAdmission.acquire`: the test of two concurrent acquires fails.

    ### Not in this task
    - Idea 5 (each entry owns a `GenerationQueue`, and `ModelHold.queue`) is step 1 and step 2 of ^qexk4w2. This task adds no queue that nothing reads.
  timestamp: 2026-09-26T21:40:04.741647+00:00
- actor: claude-code
  id: 01m3ftjhm5cf5dxm09dxs40epx
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/ModelPool/ModelPool.swift (197 lines, 124 code), Sources/FoundationModelsExtras/ModelPool/ModelPoolKey.swift (34 lines, 18 code), Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift, Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift, README.md. `swift build --build-tests`: 0 warnings. `swift test`: exit 0, 1107 tests pass (125 + 34 + 44 + 26 + 393 + 485), 0 issues. `swift test --filter ModelPoolTests`: 12 of 12 pass, 20 runs of 20.
    - next: /review
  timestamp: 2026-09-26T21:40:07.941604+00:00
- actor: claude-code
  id: 01m3fv1mbbqswqgfsmtkkv12fg
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (d18a77c): 1 finding (1 confirmed, 2 refuted). Sources/FoundationModelsExtras/ModelPool/ModelPool.swift:34 code-hygiene/idioms-swift preferForLoop. No finding asks for a lock, a semaphore, an actor or router complexity, so no conflict with the design of the user.
    - next: Convert each functional forEach call in ModelPool.swift to a for loop (all of the file, not only line 34). Then review again.
  timestamp: 2026-09-26T21:48:22.251153+00:00
- actor: claude-code
  id: 01m3fv1z0v7fpgfb00q05gr02n
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — ModelPool.swift, ModelPoolKey.swift, 12 tests, README
    - test: green — swift test, 485 passed, 0 warnings, 0 skipped
    - commit: d18a77c
    - review: findings — Sources/FoundationModelsExtras/ModelPool/ModelPool.swift:34
  timestamp: 2026-09-26T21:48:33.179360+00:00
- actor: claude-code
  id: 01m3fv2nqcwec1ggtrrf72cx3b
  text: |-
    ### Research (implement, finding pass)
    - A search for `forEach` in the repository finds 2 calls. One is in `ModelPool.swift` (`State.publish`). The other is in `TemplateEngine.swift`, which is out of the scope of this task. `Sources/FoundationModelsExtras/ModelPool/` and `Tests/FoundationModelsExtrasTests/ModelPool/` have no other `forEach`.
  timestamp: 2026-09-26T21:48:56.428866+00:00
- actor: claude-code
  id: 01m3fv513z6jth5k7h51vjhcqe
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsExtras/ModelPool/ModelPool.swift (`State.publish`: `streams.values.forEach { $0.yield(footprint) }` is now a `for stream in streams.values` loop). The finding preferForLoop is marked `- [x]`. `swift build`: exit 0, 0 warnings. `swift test --filter ModelPool`: 12 of 12 tests pass, exit 0.
    - next: /review
  timestamp: 2026-09-26T21:50:13.631961+00:00
- actor: claude-code
  id: 01m3fva3k8adtr9x76qebdfmbh
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (8c85499): 0 findings, 0 confirmed, 0 refuted; 7 validator runs, 0 failed. The prior item (ModelPool.swift:34 preferForLoop) has a check mark.
    - next: none. The task moved to done.
  timestamp: 2026-09-26T21:53:00.008574+00:00
- actor: claude-code
  id: 01m3fvae62twtg3kjbm21j0n53
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (forEach to for)
    - test: green — swift test, 485 passed, 0 warnings, 0 skipped
    - commit: 8c85499
    - review: clean — task is done. Commits of this task, in order: d18a77c, 8c85499. Each of the 12 acceptance criteria has a test in ModelPoolTests.swift (see the implement report).
  timestamp: 2026-09-26T21:53:10.850381+00:00
depends_on:
- 01M3FN8WD0G0NJ7QAAKSPZ9RW1
position_column: done
position_ordinal: bb80
title: 'ModelPool: add the pool — one load for each model, holds that release in deinit, and one admission queue'
---
## Why
In one process, each model loads one time only, and all users share it. This description REPLACES all earlier design comments on this task. The user said: "try harder to make the model pool elegant". The goal is a pool that a reader understands in one pass: about 150 lines.

## The design in five ideas
1. **The pool is a class with one `Mutex` state, not an actor.** A hold can then release in its `deinit` synchronously. No pending-release list, no drain step, no resolve lock, no `AsyncSemaphore`.
2. **Each change that can make memory larger or smaller runs as one job in one admission queue** (a `GenerationQueue`): a load and an eviction. Thus a memory decision is always correct when it runs, with no lock.
3. **An eviction job checks the hold count again when it runs.** If a caller acquired the model while the eviction job waited, the job does nothing. Thus a release and a new acquire cannot race.
4. **Footprint observation is an `AsyncStream`.** Each caller gets its own stream. No observer tokens.
5. **Each resident model owns its `GenerationQueue`.** Every hold of one key gets the same queue (task 01M3FN9BTXNPBWE6VVBQEXK4W2 uses this).

## Public API (the router and registry tasks use these names)
```swift
public enum ModelRole: Hashable, Sendable { case llm, embedding }
public struct ModelPoolKey: Hashable, Sendable { public let ref: ModelRef; public let role: ModelRole }

public protocol PooledModelLoader: Sendable {
    func load(_ key: ModelPoolKey) async throws -> any Sendable
    func evict(_ container: any Sendable) async
}

public struct ModelPoolFootprint: Sendable {
    public let resident: [ModelPoolKey: Int64]   // bytes of each resident model
    public let loadingBytes: Int64               // a load that runs now, else 0
    public var totalBytes: Int64 { get }
}

public final class ModelPool: Sendable {
    public static let shared: ModelPool
    public init()

    /// A resident key adds a hold at once. A new key loads in the admission queue.
    public func acquire(_ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64,
                        loader: any PooledModelLoader) async throws -> ModelHold

    /// Runs `job` as one admission job. `admission.acquire` inside it runs at once.
    public func admit<T: Sendable>(_ job: @escaping @Sendable (ModelPoolAdmission) async throws -> T) async throws -> T

    public var footprint: ModelPoolFootprint { get }
    public var footprints: AsyncStream<ModelPoolFootprint> { get }  // the current value first, then each change
    public var residentModelCount: Int { get }
    public func isResident(_ key: ModelPoolKey) -> Bool
}

public struct ModelPoolAdmission: Sendable {   // valid only inside its admit job
    public var footprint: ModelPoolFootprint { get }
    public func acquire(_ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64,
                        loader: any PooledModelLoader) async throws -> ModelHold
}

public final class ModelHold: Sendable {       // deinit releases
    public let key: ModelPoolKey
    public let container: any Sendable
}
```

## Rules
- Bytes: a resident model has `weightsBytes = footprintBytes - sessionBytes` from its first load, plus the `sessionBytes` of each live hold.
- `acquire` of a resident key: under the lock, add the hold and its `sessionBytes`, emit a footprint, return. No wait.
- `acquire` of a new key: `admit { try await $0.acquire(...) }`. Inside the job: if another job loaded the key already, add a hold. Else emit a footprint with `loadingBytes`, `await loader.load(key)`, insert the entry with one hold, emit a footprint. On an error: emit a footprint with `loadingBytes = 0` and throw. A later `acquire` tries again.
- The first loader of a key wins. Later callers get that container, whatever loader they give. Users get the embed operation through a protocol (task 01M3FN9BTXNPBWE6VVBQEXK4W2), never by a cast to their own container type. Write this in the doc comment of `acquire`.
- `ModelHold.deinit`: under the lock, subtract its `sessionBytes` and its hold, emit a footprint. At zero holds, submit an eviction job to the admission queue. The job: under the lock, if the key still has zero holds, remove the entry. Then (outside the lock) `await loader.evict(container)` and emit a footprint.
- JointFit and the prompt-cache sizing stay in the router. The router reads `footprints`.
- Use only Foundation, `Synchronization` and the ULID package. Short doc comments about this code only. No router history.
- Add a short README section with one `acquire` example and one `admit` example.

## Acceptance criteria
- [ ] Two concurrent `acquire` calls of one new key run the loader one time, and both get the same container.
- [ ] A resident key: `acquire` returns while an `admit` job runs (no wait).
- [ ] A new key: `acquire` started while an `admit` job runs loads only after that job ends.
- [ ] Inside `admit`, `admission.acquire` of a new key loads it with no deadlock.
- [ ] Loader A loads a key; a caller with loader B gets the container of loader A, and loader B does not run.
- [ ] The last hold release evicts the model one time; `evict` runs one time; `isResident` is then false.
- [ ] A new `acquire` between the last release and the eviction job keeps the model resident, and `evict` does not run.
- [ ] A failed load throws to its caller; a later `acquire` loads again.
- [ ] Two `footprints` streams both see each change; a stream sees `loadingBytes` during a load.
- [ ] The byte totals are correct after a load, a second hold, a release and an eviction.
- [ ] Two pools made with `init()` do not share entries.
- [ ] `swift build` has 0 warnings; `swift test` passes. The pool source is about 150 lines.

## Push order
Push the commit of 01M3FN8WD0G0NJ7QAAKSPZ9RW1 before this commit (the router has its own public `ModelPool` today). The user does or approves each push.

## Consumers
Registry tasks 01M3FNBKG7PTTAGCQNN3CRNN69, 01M3FNC0TX22X4Q7D5A5KEBHZ9. Router tasks 01M3FNB4MCRRBTJNNVZZ6P02R2, 01M3FNBKR2347W659AXFJVZKGM, 01M3FNJS6J7KGAJJ5WFEST00WA, 01M3FNK00PYXP7E102NWNHMD56, 01M3FNBZF74DHSGE70C5339RGT, 01M3FNC92WA10NG6TX59H3RKXF.

#model-pool #cross-repo

## Review Findings (2026-09-26 16:43)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsExtras/ModelPool/ModelPool.swift:34` `code-hygiene/idioms-swift` — preferForLoop: Convert functional forEach calls to for loops.
