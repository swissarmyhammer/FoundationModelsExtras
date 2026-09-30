---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3r3xkb403scrx5tydz5n4hs
  text: |-
    Research done.
    - `ModelPool.evictIfIdle` removes the entry under the state lock (no publish), awaits `loader.evict`, then publishes. Thus `footprint`, `isResident`, `residentModelCount` and the first value of a new `footprints` stream drop the model before the evict call returns. The streams that exist already see the drop only after the evict call, because the publish comes after it.
    - Contract decision: the footprint counts a model until its evict call returned (the first option of the card). Reason: the public documentation already states this contract. `footprint` is "The memory that the models use now", and `ModelPoolFootprint.resident` is "The bytes of each resident model". The second option would change that documented contract. The first option makes the code agree with it.
    - Design: `State` gets a second map `evicting: [ModelPoolKey: Int64]` for the models whose evict call runs. `entries` keeps only the models that can get holds, thus `holdIfResident` does not change and gives no hold from an evicting model. An acquire of an evicting key goes to the admission queue, which runs it after the eviction job. `footprint`, `isResident` and `residentModelCount` include `evicting`. A separate map, not a Bool flag on `Entry`, obeys the swift state-modeling rule (no flag that makes impossible states, such as holds > 0 and evicting).
    - Test seam: `RecordingLoader` gets `evictionsMayEnd`, the same shape as `loadsMayEnd`.
  timestamp: 2026-09-30T02:57:22.788866+00:00
- actor: claude-code
  id: 01m3r4a1wce44jb02xjh430nh8
  text: |-
    Implementation landed. Contract: the pool counts an evicted model until the evict call of its loader returns (the first option of the card).
    - `ModelPool.State` has a new map `evicting: [ModelPoolKey: Int64]`. `evictIfIdle` moves an idle entry from `entries` to `evicting` under the state lock (no publish, because the footprint does not change), awaits `loader.evict`, then removes the key from `evicting` in one publish. `footprint` merges `entries` and `evicting`. `residentModelCount` and `isResident(_:)` count both. `holdIfResident` did not change: it reads `entries` only, thus an evicting model gives no hold, and an acquire of that key goes to the admission queue, which runs it after the eviction job.
    - Test seam: `RecordingLoader` has `evictionsMayEnd`, the same shape as `loadsMayEnd`.
    - RED: the new test "the pool counts an evicted model until the evict call of its loader returns" failed with 4 issues (footprint `[:]`, first stream value `[:]`, `isResident` false, `residentModelCount` 0). The second new test "an acquire while the evict call runs gets no hold of the evicted model, but a new load after the evict call" passed on the old code too, because the old code removed the entry. It is a guard: it fails an implementation that keeps the evicting model in `entries` and gives holds from it.
    - GREEN: both tests pass.
    - A contract consequence: the old test "the byte totals are correct after a load, a second hold, a release and an eviction" read the footprint when the log showed "evict A", which is the START of the evict call. With the new contract that read can see the weights. The test now runs an empty admit job before that read. No assertion changed.
    - Documentation: the doc comments of `footprint`, `footprints`, `residentModelCount`, `isResident(_:)`, `evictIfIdle`, and a README paragraph under "Holds, eviction and admission jobs" state the contract. CHANGELOG has a "Fixed" entry. The doc comment of `IntegrationModels.waitForEviction` and a comment in `EvictionWaitTests` said that the pool removes the key before the evict call. They now state the new contract. The code of `waitForEviction` did not change (its empty admit job stays, and it gives the `CancellationError` that its doc names).
  timestamp: 2026-09-30T03:04:10.892684+00:00
- actor: claude-code
  id: 01m3r4a5sm233e4nbbr6qckaxf
  text: |-
    ### implement — changed
    - evidence: 7 files. Sources/FoundationModelsExtras/ModelPool/ModelPool.swift (the fix and the docs), Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift (2 new tests, 1 helper, 1 wait in theByteTotalsFollowEachChange), Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTestSupport.swift (`evictionsMayEnd`), README.md, CHANGELOG.md, IntegrationTests/.../Support/IntegrationModels.swift (doc comment), IntegrationTests/.../EvictionWaitTests.swift (one comment). RED: 1 of 2 new tests failed with 4 issues. GREEN: 2 of 2 passed. `swift test`: 806 tests in 80 suites passed, 4 known issues (the intentional `withKnownIssue` of TelemetryCaptureTests). `swift test --package-path IntegrationTests`: 24 tests in 7 suites passed. The only warning in both runs is the build-system line "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS", from the mlx-swift resource bundle; it was there before this change.
    - next: /review.
  timestamp: 2026-09-30T03:04:14.900310+00:00
position_column: doing
position_ordinal: '8180'
title: 'ModelPool: the footprint removes an evicted model before the evict call of its loader returns'
---
## What
`ModelPool.evictIfIdle` removes the entry of the key from the state, then awaits `loader.evict(container)`, and only then publishes. Thus `pool.footprint`, `pool.isResident(_:)` and the first value of a new `pool.footprints` stream show no model while the loader still frees its memory. An admission job is safe, because the admission queue runs it after the eviction job. A caller that reads the footprint outside an admission job sees memory as free too early.

## Evidence (2026-09-29, found during ^8erseht)
- In the real-model tests, about 370 MB of an `MLXLanguageModel` (its prompt cache) was still active when a new `footprints` stream showed no LLM. `MLXLanguageModel.evict()` frees that memory in the evict call.
- ^8erseht corrected the test helper `IntegrationModels.waitForEviction` with an empty admission job. The pool itself did not change.

## Acceptance Criteria
- [x] Decide the contract: the footprint counts a model until its evict call returned (for example, an "evicting" state that `holdIfResident` does not give holds from), or the documentation of `footprint` and `footprints` states that the value can drop before the memory is free.
- [x] A unit test with a loader whose evict call waits at a gate shows the chosen contract.

## Tests
- [x] `swift test` passes.

#model-pool