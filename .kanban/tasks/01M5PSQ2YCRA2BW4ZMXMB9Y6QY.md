---
comments:
- actor: wballard
  id: 01m5q7n7sa0mm177k846ewx9xt
  text: 'Done: removed ModelHold.queue, the per-entry queue and QueueName.model (the per-model QueueTelemetry path); deleted GenerationReentry.swift (ModelCallMark, SubmissionTarget, withBackgroundRunMark), GenerationQueue.refuseWaitInsideOpenSubmission and GenerationQueueError (no other case, so the type is gone); removed the withBackgroundRunMark wrapper in BackgroundToolRunner. GenerationQueue stays for ModelPool.admissions. Tests: deleted ModelCallMarkTests and the re-entry cases; the hold-shares-a-queue checks now check the shared container (unit) or the cache result (integration). README queue section rewritten. Extras swift test: 1561 tests in 160 suites passed. IntegrationTests package builds with no warnings.'
  timestamp: 2026-10-24T15:14:52.330316+00:00
- actor: wballard
  id: 01m5q86ckdm4h0whk9bps6ahvn
  text: 'Dependents against local Extras (swift package edit, swift build --build-tests, whole swift test, unedit): Router e8012983 2107 tests/266 suites passed (9 known issues); Agents c033147 670/93 passed (Router also edited to local main, because the Agents Package.resolved pins Router d1528d72, which still uses GenerationQueueError); Multitool 37d7f3d 2831/247 passed; ACP agent f377c38 1269/141 passed (1 known issue). No build warnings. Package.swift and Package.resolved unchanged in all four.'
  timestamp: 2026-10-24T15:24:14.317413+00:00
depends_on:
- 01M5PSQ2E2FKQ6SKK5T5E33SPG
position_column: done
position_ordinal: ffc880
title: Delete the per-model generation queue and ModelCallMark, after Router stops using them
---
## What

Delete the per-model generation queue and the re-entry machinery that existed only because of it. **Do this task only after FoundationModelsRouter has stopped using these APIs** (its board has the card for that). FoundationModelsACPAgent resolves Extras and Router from main, so a delete before the Router change breaks its build.

**Also depends on FoundationModelsMultitool:** its tests use `GenerationQueueError.waitInsideOpenSubmission` (`SearchToolsToolTests.swift:366`, `SampleSnippetTests.swift:224`, `ScenarioGrading.swift`). The Multitool session must remove those uses first. Run `rg -n waitInsideOpenSubmission` in Multitool, Agents and the ACP agent before you start.

Router uses today: `ModelHold.queue`, `ModelCallMark(sessionID:submission:)`, `ModelCallMark.isOpenModelCall(of:)`, `SubmissionTarget`, `GenerationQueue.refuseWaitInsideOpenSubmission()` (Router `RoutedSessionActorGeneration.swift:243-246`, `RoutedSessionActorAnswerExecution.swift:761, 838`, `RoutedSessionActorCompaction.swift:96, 457`). Check with `rg` in the Router repo before you start.

- [ ] `Sources/FoundationModelsExtras/ModelPool/ModelPool.swift`: remove the per-entry `queue` (lines 20-23, 427-428) and `ModelHold.queue` (lines 578, 594).
- [ ] **Keep `GenerationQueue`** for `ModelPool.admissions` (line 127): it runs the loads, the evictions and the joint fit in series, and never waits on a generation. Remove only its per-model use: the `QueueTelemetry(name: .model, model:)` path, and the doc comments that call it the queue of a model. Renaming the type is optional; do not do it in this task.
- [ ] Delete `Sources/FoundationModelsExtras/ModelPool/GenerationReentry.swift` (`ModelCallMark`, `SubmissionTarget`, `withBackgroundRunMark`), `GenerationQueue.refuseWaitInsideOpenSubmission()` (`GenerationQueue.swift:88, 147-150`), and `GenerationQueueError.waitInsideOpenSubmission` (`GenerationQueueError.swift`).
- [ ] `Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift:169`: remove the `ModelCallMark.withBackgroundRunMark` wrapper. The run body runs as it is. The inline settle wait (line 196) now holds no lock, so it stays.
- [ ] Remove each test of the deleted types (`ModelCallMarkTests.swift`, and the re-entry cases of `GenerationQueueWorkerTests.swift` and of the Extras `GenerationQueuePublicSurfaceTests.swift`).

## Acceptance Criteria

- [ ] `rg -n 'ModelCallMark|SubmissionTarget|refuseWaitInsideOpenSubmission|waitInsideOpenSubmission|hold\.queue|withBackgroundRunMark' Sources Tests` finds nothing.
- [ ] `GenerationQueue` is used only by `ModelPool.admissions`.
- [ ] The present `ModelPool` load and eviction tests pass unchanged.
- [ ] FoundationModelsRouter on its main, with this Extras, builds and its tests pass.

## Tests

- [ ] `swift test` in FoundationModelsExtras: all tests pass, with no new warnings.
- [ ] `swift build` and `swift test` in FoundationModelsRouter, FoundationModelsMultitool, FoundationModelsAgents and FoundationModelsACPAgent, resolved against this Extras: all pass.

## Workflow

- Use `/tdd` where you change behavior. This task is mostly a delete: the build and the present tests are the proof.