---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78hhtxpcy619cc2svzq8h9g
  text: |-
    Research (worktree agent-a0f55ec4b166094c6):
    - Each real-model suite of IntegrationTests is a nested suite of `RealModelSuites` (one `.serialized` parent), so that one real-model test runs at a time. A suite that only uses a model declares `.sharedLoads(...)`; a suite that examines its own load waits for the eviction of each model with `IntegrationModels.waitForEviction(of:in:)`. The moved suites will follow this pattern, so that no GGUF or MLX model stays resident after the suite.
    - The MLX logits suite uses `asyncMap`, which is defined only in the root test target (`InMemorySessionDirectoryFixtures.swift`). The integration package does not have it.
    - The two logits suites have the same text, candidates, tolerance and test bodies. One support file in the integration package will hold the shared checks.
    - The root `Package.swift` comment of the `FoundationModelsExtrasLlamaCppTests` target says "The one test of a real model runs only when `EXTRAS_GGUF_INTEGRATION` is `1`". The card forbids a change to the root `Package.swift`, so this comment becomes stale. A follow-up task records it.
  timestamp: 2026-11-12T18:50:33.782554+00:00
position_column: doing
position_ordinal: '8180'
title: Move the env-gated real-model suites into the IntegrationTests package, so CI runs them
---
## What
CI runs real-model tests only from the nested package `IntegrationTests/`. `.github/workflows/ci.yml` says: "No input selects tests with an environment variable." `IntegrationTests/Package.swift` also says: "Nothing reads an environment variable to select tests." Three suites do not obey this rule. They read an environment variable, so CI always skips them:
- `Tests/FoundationModelsExtrasTests/ModelPool/MLXLogitsRealModelTests.swift` (`EXTRAS_MLX_INTEGRATION`, model `mlx-community/Qwen3-0.6B-4bit`)
- `Tests/FoundationModelsExtrasLlamaCppTests/LlamaLogitsRealModelTests.swift` (`EXTRAS_GGUF_INTEGRATION`, model `Mapika/decider-2b-GGUF`)
- `Tests/FoundationModelsExtrasLlamaCppTests/LlamaCppRealModelTests.swift` (`EXTRAS_GGUF_INTEGRATION`; this suite was there before the other two)

Move each suite into `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/`, and remove the environment gate.

- [ ] Move `MLXLogitsRealModelTests.swift` to `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/MLXLogitsIntegrationTests.swift`. Remove the `.enabled(if:)` trait. The products that it needs (`FoundationModelsExtras`, `MLXFoundationModels`) are already dependencies of the integration target.
- [ ] Move `LlamaLogitsRealModelTests.swift` and `LlamaCppRealModelTests.swift` to the same folder (`LlamaLogitsIntegrationTests.swift`, `LlamaCppIntegrationTests.swift`). Remove the gates. In `IntegrationTests/Package.swift`, add the dependency `git@github.com:swissarmyhammer/FoundationModelsLlamaCpp.git` (branch `main`, the same pin as the root package), and add the products `FoundationModelsExtrasLlamaCpp` (package `..`) and `FoundationModelsLlamaCpp` to the existing integration target. Give each new dependency a comment that tells which test needs it, the same as the other entries. If a moved suite uses `FixtureSupport` or `LlamaCppTestFixtures`, add only what it needs.
- [ ] The llama tests need `swiftSettings: [.interoperabilityMode(.Cxx)]`. Add it to the existing integration target, and make sure that all the existing integration suites still compile and pass with it. Do not add a new target. If C++ interoperability prevents the existing suites from compiling, record the compiler error on this card and stop as stuck. A person must then decide about a second target.
- [ ] Remove the moved files from the root test targets. In `Tests/FoundationModelsExtrasLlamaCppTests/`, keep `LlamaCppModelLoaderTests.swift` and `LlamaLogitsTests.swift`, which do not read an environment variable. Make sure that no file in `Tests/` or `Sources/` reads `EXTRAS_MLX_INTEGRATION` or `EXTRAS_GGUF_INTEGRATION`.
- [ ] Docs: if `docs/REFERENCE.md`, `docs/GUIDE.md` or `README.md` name either variable, change the text to `swift test --package-path IntegrationTests`.

## Acceptance Criteria
- [ ] `grep -rn "EXTRAS_MLX_INTEGRATION\|EXTRAS_GGUF_INTEGRATION" Sources Tests IntegrationTests docs README.md` finds nothing.
- [ ] `swift test --package-path IntegrationTests` runs the MLX logits, llama logits and llama.cpp loader suites with no skips, and all their tests pass.
- [ ] The root `swift test` passes, and it has no skip that comes from an environment variable.
- [ ] `IntegrationTests/Package.swift` has one test target only, and the root `Package.swift` does not change.
- [ ] After the push, the CI job "Integration (opt-in, real dependencies)" runs the moved suites and passes.

## Tests
- [ ] Run `swift test --package-path IntegrationTests`. All tests pass, and the log shows the moved suites.
- [ ] Run `swift test` at the root. All tests pass.
- [ ] Run the grep of the first acceptance criterion. It gives no result.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. For this move: first make the moved suites compile and run in the integration package, then remove the old files. #decision