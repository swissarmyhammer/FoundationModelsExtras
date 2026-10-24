---
depends_on:
- 01M5PSQ2E2FKQ6SKK5T5E33SPG
position_column: todo
position_ordinal: '8380'
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