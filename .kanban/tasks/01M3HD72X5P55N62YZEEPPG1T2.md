---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hf3gw7k3cw4g710ev8nyhq
  text: |-
    Research done.
    - The FoundationModelsRouter integration suite does not read MLX memory counters. These tests use `MLX.Memory.activeMemory` (mlx-swift `Source/MLX/Memory.swift`). It counts live MLX buffers. Freed buffers go to `Memory.cacheMemory`, which it does not count.
    - `MLXLanguageModel` keeps its weights in a process-global model cache keyed by `modelID`. Thus two pools in one process share weights. Each test must wait for the eviction of its models before it ends; else a late eviction job of one test evicts the weights under the hold of the next test.
    - Swift Testing runs suites in parallel. `.serialized` on one suite does not stop a parallel suite. Memory checks need one real-model test at a time, thus all real-model suites go under one `.serialized` parent suite (`RealModelSuites`), and the smoke suite moves under it.
    - `MLXLanguageModel` is a struct, thus "the same container" is checked as the same pool entry (`hold.queue ===`) and the same `modelID`.
    - `ModelCallMark` needs a `ULID`, thus the IntegrationTests package adds the ULID.swift product (same URL and floor as the root package).
    - No lock, semaphore or gate type: a small actor records events; tests poll `waitingCount`/`isRunning` with a short sleep, under the time limit.
  timestamp: 2026-09-27T12:58:10.183900+00:00
- actor: claude-code
  id: 01m3hfxk7712a2q66yb37hh55p
  text: |-
    Implementation landed. The tests found no defect in the Extras code; no library file changed.
    - New suites: `ModelPoolIntegrationTests.swift` (one load, eviction memory, admission order) and `GenerationQueueIntegrationTests.swift` (FIFO one at a time, cancel of a waiting job, cancel of the running job, re-entry refusal).
    - New support: `RealModelSuites` (one `.serialized` parent suite; also holds `testTimeLimitMinutes = 10`), `ModelMemory` (MLX `Memory.activeMemory`, and the weight-file bytes from the Hugging Face cache), `RecordingLoader`, `EventLog` (an actor), `Generation`, `Waiting` (poll with a 10 ms sleep).
    - Changed: the smoke suite is now nested under `RealModelSuites` and uses the shared helpers; `IntegrationModels.acquire` takes an optional loader, and `waitForEviction` moved there; `MLXPooledLoader.defaultRevision` is internal; `Package.swift` adds the ULID product.
    - Measured values (these fix the tolerance): the load added 695,312,152 bytes for weight files of 695,283,921 bytes; less than 7 KB stayed after the eviction; the cancelled generation stopped 6 ms after the cancel. The memory tolerance is a tenth of one model (about 70 MB). The reason is in the doc comment of `toleranceDivisor`.
    - To prove that the checks can fail: a run with a tolerance of 1/100000 of a model and with 1 ns time limits failed the 2 memory checks and the 2 time checks with the values above. The limits then went back.
    - Note: free disk space fell from about 9 GB to about 3.6 GB during the builds (build products only; no model download).
  timestamp: 2026-09-27T13:12:24.551217+00:00
- actor: claude-code
  id: 01m3hfxr0rkt7s98js4mrb28wx
  text: |-
    ### implement — changed
    - evidence: 14 files in IntegrationTests/ (new: ModelPoolIntegrationTests.swift, GenerationQueueIntegrationTests.swift, Support/RealModelSuites.swift, Support/ModelMemory.swift, Support/RecordingLoader.swift, Support/EventLog.swift, Support/Generation.swift, Support/Waiting.swift; changed: Package.swift, ModelPoolSmokeTests.swift, Support/IntegrationModels.swift, Support/MLXPooledLoader.swift). Root `swift test`: 726 tests in 69 suites passed (plus 125, 34, 44, 26, 396 in the other test products), 32.5 s wall time. `swift test --package-path IntegrationTests` with the final code, 3 runs in a row: 9 tests in 4 suites passed each time; wall time 42.9 s, 41.5 s, 45.6 s (test time 22.9 s, 23.2 s, 25.3 s). Only warning: the accepted SwiftPM Cmlx bundle warning.
    - next: /review
  timestamp: 2026-09-27T13:12:29.464802+00:00
- actor: claude-code
  id: 01m3hfxvdhnza53q6xj6pdamx9
  text: 'Correction to the step record above: the count is 12 files (8 new, 4 changed), not 14. The list in the record is correct.'
  timestamp: 2026-09-27T13:12:32.945379+00:00
- actor: claude-code
  id: 01m3hgbxsxm4fq8svved7smxz1
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (a4dfe5d); 6 findings (6 confirmed, 1 refuted) — GenerationQueueIntegrationTests.swift:20, GenerationQueueIntegrationTests.swift:26, GenerationQueueIntegrationTests.swift:188, Support/IntegrationModels.swift:31, Support/Waiting.swift:7, Support/Waiting.swift:14. No finding asks for a lock, semaphore, gate, actor or router, so no finding conflicts with the user decision.
    - next: implement the open items in the "Review Findings (2026-09-27 08:13)" section. Apply each cause to the whole file. Then review again.
  timestamp: 2026-09-27T13:20:14.141787+00:00
- actor: claude-code
  id: 01m3hgcc6c41b1ht2cvbqa6t2f
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 real-model tests, serialized parent suite, support files
    - test: green — root 726 passed; IntegrationTests 9/9 passed 3 runs in a row
    - commit: a4dfe5d
    - review: findings — GenerationQueueIntegrationTests.swift:20, :26, :188; Support/IntegrationModels.swift:31; Support/Waiting.swift:7, :14
  timestamp: 2026-09-27T13:20:28.876408+00:00
- actor: claude-code
  id: 01m3hghzc1nhgj7qc0svp8ker4
  text: |-
    Review findings fixed. Each cause is removed from the whole of each file.
    - magic-numbers-swift: the rule is swiftlint `no_magic_numbers` (allowed 0, 1, -1, 100). It reports a literal in a call such as `Duration.seconds(2)`, also inside a `let`. A plain `let x = 2` and a shift (`1 << 30`, `64 << 20`) are not reported. Fix: new named integer constants `decodeSecondsBeforeCancel`, `cancelledStopLimitSeconds` (GenerationQueueIntegrationTests.swift) and `pollIntervalMilliseconds` (Waiting.swift); the `Duration` constants use them. A local swiftlint run with the rule config on the 3 files now reports 0 (before: 3, the same 3 lines as the findings).
    - fluent-usage: `isTurn(turn:of:)`, `IntegrationModels.acquire(key:in:loader:)`, `Waiting.until(condition:)`. Same cause in the same file: `JobRecord.run(_ prompt:)` became `JobRecord.run(prompt:with:maximumResponseTokens:)`. The `_ body` parameters are not the first argument, thus the rule does not apply to them.
    - Callers updated in IntegrationTests/: GenerationQueueIntegrationTests.swift, ModelPoolIntegrationTests.swift (3 calls), ModelPoolSmokeTests.swift (2 calls). The `Waiting.until { ... }` callers use a trailing closure, which drops the label, thus they did not change.
    - Note: a `replace_all` edit of the files tool changed only 1 of 2 matches two times; a grep after the edits found no old call.
  timestamp: 2026-09-27T13:23:32.353002+00:00
- actor: claude-code
  id: 01m3hgj21vzp7fe249747wjevp
  text: |-
    ### implement — changed
    - evidence: 5 files — IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/GenerationQueueIntegrationTests.swift, Support/IntegrationModels.swift, Support/Waiting.swift, ModelPoolIntegrationTests.swift, ModelPoolSmokeTests.swift. `swift build --package-path IntegrationTests --build-tests`: build complete, 0 compiler warnings (only the accepted SwiftPM Cmlx bundle warning). `swift test --package-path IntegrationTests` (1 run): 9 tests in 4 suites passed after 24.2 s. 6 of 6 findings marked `- [x]`.
    - next: /review
  timestamp: 2026-09-27T13:23:35.099295+00:00
depends_on:
- 01M3HD6T6P13MA52XSVQ8EEGJF
position_column: doing
position_ordinal: '80'
title: 'Integration tests 2: real-model tests of ModelPool and GenerationQueue'
---
## Why
The unit tests prove the pool and the queue with fakes. These tests prove them with real MLX models in the nested `IntegrationTests/` package (task 01M3HD6T6P13MA52XSVQ8EEGJF), where memory, load time and the GPU are real.

## Tests to add (use private `ModelPool()` instances, the real `MLXPooledLoader`, and the small models from `Support/`)
- [x] One load for each model: two concurrent `acquire` calls of the same real LLM key load it one time (count loader calls), both holds get the same container, and the process memory grows by about one model, not two.
- [x] Eviction frees memory: after the last hold is released, the eviction job runs, `isResident` is false, and the MLX active memory falls back near the value before the load.
- [x] Admission order: an `admit` job that measures `footprint` and loads model A, and a plain `acquire` of model B started during that job; B loads only after the job ends, and `footprints` shows the loads one at a time with correct `loadingBytes`.
- [x] One call at a time on the GPU: several concurrent generations submitted to one hold's `GenerationQueue` run one at a time, in FIFO order (record start and end times of each job), and each gives a real answer.
- [x] Cancel of a waiting job: a generation that waits in the queue and is cancelled never starts.
- [x] Cancel of the running job: a cancel of a long real generation stops it early (well before its token limit), and the next job then runs.
- [x] Re-entry refusal: a job that submits to its own queue from inside an open model call gets `waitInsideOpenSubmission` at once and does not hang.
- Give each test a time limit, so that a hang fails and does not block CI.
- Simple test code; no lock/semaphore/gate types.

## Acceptance criteria
- [x] `swift test --package-path IntegrationTests` passes on this machine, 3 runs in a row.
- [x] The root `swift test` is unchanged and passes.

#integration-tests

## Review Findings (2026-09-27 08:13)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 12 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/GenerationQueueIntegrationTests.swift:20` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/GenerationQueueIntegrationTests.swift:26` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/GenerationQueueIntegrationTests.swift:188` `swift/fluent-usage` — The `_ turn` parameter omits its label, violating the fluent-usage rule which restricts omitting the first argument label to value-preserving conversions only. The call site `isTurn(turn, of: queue)` would be clearer with an explicit label: `isTurn(turn: turn, of: queue)`. Change `_ turn:` to `turn:` to include the label.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/IntegrationModels.swift:31` `swift/fluent-usage` — The `_ key` parameter omits its label, violating the fluent-usage rule which restricts omitting the first argument label to value-preserving conversions only. The call site `IntegrationModels.acquire(IntegrationModels.llm, in: pool)` would be clearer as `acquire(key: ..., in: ...)`. Change `_ key: ModelPoolKey` to `key: ModelPoolKey` to include the label.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/Waiting.swift:7` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/Support/Waiting.swift:14` `swift/fluent-usage` — The `_ condition` parameter omits its label, violating the fluent-usage rule which restricts omitting the first argument label to value-preserving conversions only. While closure-taking functions often use trailing closure syntax, the rule is explicit and does not make an exception for closures. Change `_ condition:` to `condition:` to include the label.
