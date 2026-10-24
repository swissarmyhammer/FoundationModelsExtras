---
comments:
- actor: wballard
  id: 01m5pzt1gmpwce93td54zx1y26
  text: 'Done. PooledSession.generate runs the SDK respond on the caller''s task (no hold.queue.submit); GenerateRelayExecutor.respond sends each model round (both the slot branch and the no-call branch) through PooledGeneration.run, with the scope from the shared PooledGeneration.cacheScope(of:) (task-local scope, else first transcript entry id) and GenerateRelayModel now carries the ModelRef for the in-flight meter. fork() deleted with its doc example and tests; with it went the fork-only stored pool/tools and PooledSessionStart, and the init is now init(hold:tools:instructions:) (internal). GenerateCallSlot is still correct: it is per PooledSession, and one LanguageModelSession refuses a concurrent call (LanguageModelSession.Error.concurrentRequests); comment names that rule. PooledEmbedder.embed calls the container at once (MLX EmbedderModelContainer lock). Doc comments, GenerateTelemetry/SpanName.generate docs and README updated (fork section and example removed; GenerationQueue section notes the pooled types no longer use it). Integration test aForkRemembersAFactOfItsParent became aSessionRemembersAFactOfAnEarlierTurn (fork gone); IntegrationTests package builds. Tests: aToolThatUsesTheSameModelCompletes, twoSessionsTakeTurnsForEachGeneration (both hang under the old queue, which is the bug), aPooledSessionRespondRunsInNoQueueJob and anEmbedCallRunsInNoQueueJob (clean red before). Embedder FIFO/cancel tests restated on a FIFO lock in FakeEmbedding; ModelPoolTests embed-records-a-queue-task restated as a direct hold.queue.submit (queue metrics stay for Router). swift test: 2223 tests, 0 failures.'
  timestamp: 2026-10-24T12:57:41.140969+00:00
depends_on:
- 01M5PSQ1XBPRF64B1NPTCWS0HJ
position_column: done
position_ordinal: ffc780
title: Remove the queue job from PooledSession and PooledEmbedder, and delete the unused PooledSession.fork()
---
## What

Remove the per-model queue job from `PooledSession` and `PooledEmbedder`, and delete the unused `PooledSession.fork()`.

**`PooledSession`** (`Sources/FoundationModelsExtras/ModelPool/PooledSession.swift`):
- [ ] `generate` (about lines 112-121) runs the SDK `respond` call on the caller's task, with no `hold.queue.submit` around it. `GenerateRelayExecutor.respond` (`GenerateRelayModel.swift`) calls the model through `PooledGeneration.run(ref:channel:_:)`, from the task "Call the MLX model directly..." (the in-flight meter and the cancel). Keep PooledSession's own `GenerateTelemetry` span; the helper opens none. Thus only the call into the model is serialized (MLX's lock), and the session's tool bodies run outside every lock.
- [ ] **Delete `fork()`** (about lines 123-136) and its doc example (line 16). Nothing in any package calls it (checked 2026-10-24 across every `Sources/` in `swissarmyhammer/`). Remove its tests.
- [ ] `GenerateCallSlot` (`GenerateRelayModel.swift:10, 33-34`): its comment relies on the queue running one `respond` at a time. Now the SDK gives that rule: one `LanguageModelSession` refuses a second concurrent call (`LanguageModelSession.Error.concurrentRequests`). Check that the slot is still correct, and change the comment to name the SDK rule.
- [ ] Update the doc comments that say "the call waits in the queue of the model" (lines 28, 32, 42, 48, 58-72).

**`PooledEmbedder`** (`Sources/FoundationModelsExtras/ModelPool/PooledEmbedder.swift:66`):
- [ ] Remove `loaded.hold.queue.submit`. MLX's embedder container has its own `SerialAccessContainer` lock (mlx-swift-lm `MLXEmbedders/EmbedderModelContainer.swift:30`), held for one embed. Keep the present embed telemetry.

## Acceptance Criteria

- [ ] No `hold.queue.submit` in `PooledSession.swift` or `PooledEmbedder.swift`.
- [ ] **A tool that uses the same model completes.** A `PooledSession` whose tool body calls `respond` on an other `PooledSession` of the same pooled model gets that answer, and its own call completes (no deadlock, no refusal). Use a stub model with a FIFO serial lock around each generation, as MLX does.
- [ ] Two `PooledSession`s on one model take turns per generation, not per whole call: while session A's tool body waits on a signal, a generation of session B runs and ends.
- [ ] `PooledSession` has no `fork()`, and the package still builds.
- [ ] Two embed calls on one pooled embedder give the same results as before.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/PooledModelTests.swift` (the PooledSession tests are there): the criteria above. Remove the fork tests.
- [ ] The present `PooledEmbedder` tests still pass.
- [ ] `swift test` in FoundationModelsExtras: all tests pass, with no new warnings.

## Workflow

- Use `/tdd`: write the failing tests first, then implement until they pass.