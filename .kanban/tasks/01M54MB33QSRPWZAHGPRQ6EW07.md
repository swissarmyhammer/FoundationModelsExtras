---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m551cehtmc3pq0z2bpv62d0b
  text: |-
    Phase 1 research (no test changed yet).

    - The line numbers on the card are from the version before the commit 774663a. The tests are found by content.
    - Loads now: 41 real loads. LLM 1B: 11. Embedding: 16. Qwen3-4B: 14. Each test makes its own ModelPool and loads each model again.
    - A load of one LLM for each process is not possible. MLXLanguageModel keeps its weights in one static ModelCache for each process (mlx-swift-lm MLXLanguageModel.swift). MLXModelLoader.evict calls MLXLanguageModel.evict, which removes the cache entry. The tests that measure their own load (ModelPool, MLX loader, cold/warm span) load and evict the same LLMs in their own pools. MLXEmbedding has no process cache, and its evict does nothing.
    - Proposal: a suite trait (SuiteTrait and TestScoping) in Support loads the models of one suite one time, gives them through a task local, and releases the holds and waits for the eviction after the last test, also on a throw.
    - The list of removals and the fixture design went to the coordinator for review. No deletion before the approval.
  timestamp: 2026-10-17T13:38:53.114113+00:00
- actor: claude-code
  id: 01m5531kscn11q2qcaqvv6ry58
  text: |-
    Removed and merged tests, each with its cover. The peer approved the list before the deletion. IT = IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests, UT = Tests/FoundationModelsExtrasTests.

    1. IT ModelPoolSmokeTests generatesThroughThePoolAndEvictsAfterTheRelease: removed. Cover: IT GenerationQueue cancelledRunningGenerationStopsEarly (a generation in the queue of the hold, the answer holds "Paris") and IT ModelPool concurrentAcquiresLoadOneModelThatTheEvictionFrees (!isResident after the eviction).
    2. IT ModelPoolSmokeTests embedsThroughThePoolAndEvictsAfterTheRelease: removed (the file is gone). Cover: IT PooledEmbedder realEmbedByNamePlacesSimilarTextsCloser; UT ModelPoolTests theLastReleaseEvictsOneTime and UT PooledEmbedderTests theHandleKeepsTheModelResident.
    3. IT GenerationQueue concurrentGenerationsRunOneAtATimeInOrder: removed. Cover: UT GenerationQueueWorkerTests itemsFromThreeTasksRunInOrderWithNoOverlap.
    4. IT GenerationQueue cancelledWaitingJobNeverStarts: removed. Cover: UT GenerationQueueWorkerTests aCancelledWaitingItemNeverRunsAndTheNextItemRuns and aCancelledWaitingItemLeavesTheCountWhenTheCancelReturns.
    5. IT GenerationQueue submissionInsideAnOpenModelCallIsRefused: removed. Cover: UT GenerationQueueWorkerTests aSubmissionInsideAnOpenSubmissionOnTheSameQueueIsRefused.
    6. IT ModelPool acquireWaitsForTheRunningAdmissionJob: removed. Cover: UT ModelPoolTests newKeyAcquireLoadsAfterTheAdmitJob, which now also checks the footprint stream (the second load starts only after the first model is resident). Fault demo: ModelPool.acquire changed to load outside the admission queue; the footprint check failed (with the two log checks); the change was reverted.
    7. IT ModelPool acquireByKeyLoadsEachModelByName: changed to the arguments [embedding, llm] (L1B in place of Q4B).
    8. IT ModelPool aLoadEndsWithReady: merged into aRealLoadReportsItsBytesAndEndsWithReady (one load, both checks).
    9. IT PooledEmbedder twoUsersShareOneLoadOfTheModel: removed. Cover: UT ModelPoolTests theFirstLoaderWins, UT PooledEmbedderTests aCallerWithLoaderBEmbedsWithTheModelOfLoaderA and twoEmbeddersOfOneNameShareOneModel, IT ModelPool acquireByKeyLoadsEachModelByName(embedding).
    10. IT PooledEmbedder concurrentEmbedsRunOneAtATimeInOrder: removed. Cover: UT PooledEmbedderTests concurrentCallsRunOneAtATimeInOrder.
    11. IT PooledEmbedder embedderHandleKeepsTheModelResident: removed. Cover: UT PooledEmbedderTests theHandleKeepsTheModelResident and theLastCopyOfTheLastEmbedderEvictsTheModel.
    12. IT PooledEmbedder embedDoesNotWaitBehindAGeneration: changed. The generation waits at a latch after its first snapshot. The latch opens when the embed call returned, or when a second job waits in the queue of the LLM. The token count is now 256 and changes only the time. Fault demo: the embed call went through the queue of the LLM; the order check failed after 1.5 s with no hang; the change was reverted.
    13. IT ToolHosting fastBackgroundRunAnswersInsideTheGrace: removed. Cover: UT BackgroundToolRunnerTests runSettlingInsideTheGraceAnswersWithItsOwnOutput and defaultSiteGraceSettlesAFastRunInline; IT ToolHosting inBandToolRunsToCompletion.
    14. IT ToolHosting cancelSettlesTheRunWithTheCancelerOutcome: removed. Cover: UT DeclaredRunKindTests aToolDeclaringNothingKeepsTheCooperativeCanceler, UT BackgroundToolRunnerTests cancellingBackgroundRunYieldsOneCancelledTerminal; IT ToolHosting backgroundToolSettlesAfterItsEnvelope.
    15. IT ToolHosting perCallMountOfOneTool: removed, perCallMountOfAnOperationTool stays. Cover: OperationTool uses the same BackgroundTool.mount(for:) hook; UT PerCallMountTests eachCallGetsTheMountOfItsArguments.
    16. IT PooledModel aLanguageModelSessionAnswers: removed. Cover: IT PooledModel twoCallsOpenAColdAndThenAWarmGenerateSpan (same session, same prompt, requires "paris").
    17. IT MLXModelLoader aLoadUsesTheGivenTokenizerLoader: merged into aLoadUsesTheGivenTokenizerLoaderAndOpensItsPhaseSpans (one load for each key).
    18. IT PooledEmbedder mixedLengthCallPadsFarFewerTokensThanOnePaddedBatch: merged into anEmbedCallOpensItsSpanTreeWithTheRealCounts (the same span-based padding check).
    19. IT ModelPool concurrentAcquiresLoadTheModelOneTime and evictionFreesTheMemoryOfTheModel: merged into concurrentAcquiresLoadOneModelThatTheEvictionFrees.

    Fixture: Support/SharedModels.swift, SharedLoadsTrait (SuiteTrait, TestScoping, isRecursive false). GenerationQueue, PooledEmbedder, PooledModel and ToolHosting use it. ModelPool, MLXModelLoader and the PooledModel telemetry suite have no trait.
    Real loads: before 41 (LLM 11, embedding 16, Q4B 14). After 12 (LLM 5, embedding 4, Q4B 3).
  timestamp: 2026-10-17T14:07:55.180299+00:00
- actor: claude-code
  id: 01m55322kaxvv4sdbt8e5rtwzq
  text: |-
    ### implement — changed
    - evidence: 8 local commits 4c96d32..813a73a (not pushed). One IntegrationTests run: 26 tests in 10 suites passed in 51.2 s (metallib copied beside the test binary, copies removed after the run). One root swift test run: 1223 tests in 120 suites passed, plus the other test runs of the root package passed, with no issue and no warning.
    - open: the card needs the CI integration time before and after. That needs a push and a CI run, and this step does not push.
    - next: the coordinator pushes when the runner is free, and records the CI times; then review.
  timestamp: 2026-10-17T14:08:10.346031+00:00
depends_on:
- 01M53BTZ0M0DH3HXBD47N7BNKZ
- 01M54QGXNTCEDD848YPNBB4PPJ
position_column: doing
position_ordinal: '80'
title: 'IntegrationTests: share the model loads and remove redundant tests'
---
## Goal

Make the integration tests use less time in CI. Do not change swift-ci.yaml or the .github files.

## Scope

1. Share the model loads.
   - Load each model one time in each suite. If the pool already permits it, load each model one time in each process.
   - Put the shared fixture in IntegrationTests/Support.
   - Each test must close or release what it holds. This is also necessary when the test throws.
   - Do not add a clock, sleep, poll, retry or time limit.
2. Remove redundant tests.
   - Remove a test only when a different test proves the same behavior.
   - Make a list on this card. For each test to remove, write the test that covers it.
   - Send the list to the peer session before you delete a test. The peer reviews the list.
   - The first candidates are: MPS:12, MPS:24, GQ:61, GQ:83, GQ:140, MP:68, MP:106 (merge it into MP:119), PE:191, PE:210, PE:226, TH:111, TH:129. Also merge TH:199 and TH:220, use L1B in place of Q4B in MP:90, and give PE:242 fewer tokens.
3. Report the integration time before and after. Use the CI times. Do not use repeated local runs.

## Order

Start this card only after ^7n7bnkz is done. Do not do the two cards at the same time.

## Acceptance

- Each model loads one time in each suite, or one time in each process.
- The peer approved the list of removed tests before the deletion.
- One full local run passes. CI passes.
- The card records the CI integration time before and after.