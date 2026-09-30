---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3r1hvsb9xwjzqkgtq5g44zn
  text: |-
    Research done. The cause is known.
    - Data: a temporary print in `acquireConcurrently` (8 runs of the filtered command). 7 runs passed with `before=7272`, prompt cache 0 bytes. The 1 failing run had `before=369578344` and `MLXLanguageModel.promptCacheUsage.memoryBytes=8388608` at the start of the measure. After the load: active 695614408 bytes, prompt cache 0. Thus the load itself is correct. The measure started while about 369 MB of the prior test (the prompt cache entry of the last GenerationQueue test and the arrays that it keeps) was still alive, and `MLXLanguageModel.evict()` freed that memory during the load.
    - Why: `ModelPool.evictIfIdle` removes the entry from the state (no publish), then awaits `loader.evict(container)`, then publishes. `pool.footprints` gives the current footprint first. When the test helper `IntegrationModels.waitForEviction` makes its stream after the removal and before the end of `evict`, the first footprint has no entry, and the helper returns at once. `MLXLanguageModel.evict()` (ModelCache.remove, then `ExecutorPromptCacheStore.evict(modelID:)`) still runs. The next test then reads `bytesBefore` too early.
    - It is a race in the test helper, also on HEAD. The MLX link in the core only changes the timing. `otool` showed one MLX copy, and the data shows one model of memory after the load, thus two MLX copies are not the cause.
    - Fix plan: `waitForEviction` also waits for an empty admission job. The release puts the eviction job in the admission queue in the same step, and the queue runs jobs first in first out, thus the empty job ends only after `loader.evict` returned.
  timestamp: 2026-09-30T02:16:01.067913+00:00
- actor: claude-code
  id: 01m3r2ng2ey8ydk1ttchjr9qvk
  text: |-
    Implementation landed. The tree of ^483vhbg is not changed.
    - RED: new test `EvictionWaitTests` ("waitForEviction returns only after the evict call of the loader returned") in IntegrationTests. A fake loader holds its evict call at a gate, so the test needs no real model and no MLX, and it runs in 0.1 s. With the old helper: "Expectation failed: try await evictionEndedAtReturn".
    - GREEN: `IntegrationModels.waitForEviction` is now `async throws`. After the footprint shows no key, it runs `try await pool.admit { _ in }`. The doc comment gives the cause. All 27 call sites now use `try await`. The temporary debug prints are removed.
    - The tolerance of the memory check did not change.
    - Proof: filtered loop (GenerationQueueIntegrationTests + concurrentAcquiresLoadTheModelOneTime) 0 failures in 12 runs, 5 tests in each run. Full `swift test --package-path IntegrationTests` 3 of 3 passed (24 tests in 7 suites each). `swift test` 804 tests passed; the 4 known issues are the intentional `withKnownIssue` of `TelemetryCaptureTests`. The only warning is the build-system line "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS", from the mlx-swift resource bundle.
    - New task ^7zpkqhy: the pool footprint drops an evicted model before the evict call of its loader returns. That is a pool contract question, outside this card.
  timestamp: 2026-09-30T02:35:28.718167+00:00
- actor: claude-code
  id: 01m3r2nt9xwt15xte0vqa5x2gy
  text: |-
    Correction to the comment above: the call sites of `waitForEviction` are 23, not 27. 22 are old call sites that now use `try await`, and 1 is in the new `EvictionWaitTests`.

    ### implement — changed
    - evidence: 7 files. New: IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/EvictionWaitTests.swift. Changed: Support/IntegrationModels.swift (the fix), and the `try await` call sites in GenerationQueueIntegrationTests.swift, ModelPoolIntegrationTests.swift, ModelPoolSmokeTests.swift, PooledEmbedderIntegrationTests.swift, ToolHostingIntegrationTests.swift. RED 1 fail, then GREEN 1 pass (`--filter EvictionWaitTests`). Filtered loop: 0 failures in 12 runs. `swift test --package-path IntegrationTests`: 3 of 3 passed, 24 tests each. `swift test`: 804 passed (4 intentional known issues).
    - next: /review. New task ^7zpkqhy holds the pool footprint contract.
  timestamp: 2026-09-30T02:35:39.197901+00:00
position_column: doing
position_ordinal: '8180'
title: 'ModelPoolIntegrationTests: the memory check of "two concurrent acquires of the real LLM" fails some of the time'
---
## What
The integration test "two concurrent acquires of the real LLM load it one time, share one container, and add one model of memory" (`concurrentAcquiresLoadTheModelOneTime` in `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/ModelPoolIntegrationTests.swift`) fails some of the time. The MLX active memory grows by less than one model:

- "MLX active memory grew 368921240 bytes; one model is 695283921 bytes"
- "MLX active memory grew 312732056 bytes; one model is 695283921 bytes"
- "MLX active memory grew 378882712 bytes; one model is 695283921 bytes"

## Evidence (2026-09-29, found during ^483vhbg)
- Command: `swift test --package-path IntegrationTests --filter 'GenerationQueueIntegrationTests|concurrentAcquiresLoadTheModelOneTime'`, and the full `swift test --package-path IntegrationTests`.
- With the working tree of ^483vhbg (the core target links MLX): 3 failures in 10 runs. The test passes alone. It fails only after the `GenerationQueueIntegrationTests` suite.
- With the baseline (HEAD, the core target with no MLX): 0 failures in 5 runs.
- With a temporary `print` of `ModelMemory.activeBytes` just after the two acquires: 4 of 4 runs passed, and each print showed `before=7272 after=695253888`. The failing value is read a moment later, in the `SharedHolds` initializer. Thus the active memory can go down after the load returns, or the load can return before all weights are evaluated.
- The cause is not known. The test binary links MLX statically one time (`otool -L` shows no second copy).

## Cause (2026-09-30)
`ModelPool.evictIfIdle` removes the entry, then awaits `loader.evict`, then publishes. The test helper `IntegrationModels.waitForEviction` returned when a new `footprints` stream showed no key, thus it could return before `MLXLanguageModel.evict()` freed the prompt cache of the last GenerationQueue test (about 370 MB). The next test then read `bytesBefore` too high. The fix: the helper also waits for an empty admission job, which runs after the eviction job. The pool contract is task ^7zpkqhy.

## Acceptance Criteria
- [x] The cause is known and written on this task.
- [x] The memory check reads a stable value (for example, it waits until MLX finished the load, or until the memory of the prior test is free).
- [x] 10 runs of the command above in sequence pass.

## Tests
- [x] `swift test --package-path IntegrationTests` passes 3 times in sequence.

## Workflow
- Use `/tdd`. #model-pool