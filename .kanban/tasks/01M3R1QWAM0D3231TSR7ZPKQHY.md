---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: 'ModelPool: the footprint removes an evicted model before the evict call of its loader returns'
---
## What
`ModelPool.evictIfIdle` removes the entry of the key from the state, then awaits `loader.evict(container)`, and only then publishes. Thus `pool.footprint`, `pool.isResident(_:)` and the first value of a new `pool.footprints` stream show no model while the loader still frees its memory. An admission job is safe, because the admission queue runs it after the eviction job. A caller that reads the footprint outside an admission job sees memory as free too early.

## Evidence (2026-09-29, found during ^8erseht)
- In the real-model tests, about 370 MB of an `MLXLanguageModel` (its prompt cache) was still active when a new `footprints` stream showed no LLM. `MLXLanguageModel.evict()` frees that memory in the evict call.
- ^8erseht corrected the test helper `IntegrationModels.waitForEviction` with an empty admission job. The pool itself did not change.

## Acceptance Criteria
- [ ] Decide the contract: the footprint counts a model until its evict call returned (for example, an "evicting" state that `holdIfResident` does not give holds from), or the documentation of `footprint` and `footprints` states that the value can drop before the memory is free.
- [ ] A unit test with a loader whose evict call waits at a gate shows the chosen contract.

## Tests
- [ ] `swift test` passes.

#model-pool