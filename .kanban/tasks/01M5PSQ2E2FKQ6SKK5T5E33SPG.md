---
depends_on:
- 01M5PSQ1XBPRF64B1NPTCWS0HJ
position_column: todo
position_ordinal: '8280'
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