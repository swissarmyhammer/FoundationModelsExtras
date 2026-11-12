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
- actor: claude-code
  id: 01m78jqhqz5k446bd4aca4b3ba
  text: |-
    ### implement — changed
    - evidence: 7 files — IntegrationTests/Package.swift (llama.cpp dependency, products `FoundationModelsExtrasLlamaCpp` and `FoundationModelsLlamaCpp`, `.interoperabilityMode(.Cxx)` on the one test target); moved and ungated MLXLogitsIntegrationTests.swift, LlamaLogitsIntegrationTests.swift, LlamaCppIntegrationTests.swift (nested in `RealModelSuites`; the logits suites use `.sharedLoads`, the loader suite waits for each eviction); new Support/LogitsChecks.swift (the shared logits checks); Support/ModelAvailability.swift (the message names MLX and llama.cpp).
    - C++ interop: all existing integration suites compile with it. No compiler error.
    - Note: in this worktree, `swift test --package-path IntegrationTests` fails with "unknown package 'FoundationModelsExtras'", because SwiftPM gives the path dependency `..` the identity of the folder name (`agent-…`). The run was done in a copy of the worktree in a folder named `FoundationModelsExtras`. This does not occur in CI or in the main checkout.
    - Follow-up: ^7y79cd8 (stale comment in the root Package.swift).
    - next: test
  timestamp: 2026-11-12T19:11:09.567433+00:00
- actor: claude-code
  id: 01m78jqrh8vxbqxr4gsnmnvhq2
  text: |-
    ### test — green
    - evidence: `swift test --package-path IntegrationTests`: 56 tests in 14 suites passed, 0 failed, 0 skipped. The log shows "MLX logits with a real model", "LlamaCpp logits with a real model" and "LlamaCpp loader with real models" passed. Root `swift test`: all runs passed (1831 tests in 176 suites, 401 in 27, 136 in 12, 46 in 10, 40 in 4, 26 in 5, 18 in 2), 0 failed. The grep for `EXTRAS_MLX_INTEGRATION\|EXTRAS_GGUF_INTEGRATION` over Sources Tests IntegrationTests docs README.md gives no result.
    - next: commit
  timestamp: 2026-11-12T19:11:16.520078+00:00
- actor: claude-code
  id: 01m78jy1wrnvc7gvqy3n6b6s9c
  text: |-
    ### review — findings
    - evidence: `review sha ddf5bf7..eb47bc5` (9 files, all in this worktree): 2 findings — LlamaLogitsIntegrationTests.swift:63, LlamaLogitsIntegrationTests.swift:64 (`reuse/reuse`). The swift tool rules reported "found no file" for the four new files, because the review tool reads the main checkout, which does not hold them.
    - next: implement the findings

    ### finish iteration 1 — findings
    - implement: changed — 9 files (the move, the Package.swift change, LogitsChecks, ModelAvailability)
    - test: green — integration 56 tests in 14 suites passed; root swift test passed
    - commit: eb47bc5 test(integration): move the real-model logits and llama.cpp suites into IntegrationTests
    - review: findings — 2 (LlamaLogitsIntegrationTests.swift:63, :64)
  timestamp: 2026-11-12T19:14:42.712028+00:00
- actor: claude-code
  id: 01m78ka2ygwnmnjnrhr9ebgb93
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — Support/LogitsChecks.swift (an overload of `expectFiniteAndNotPositive` that takes the candidates and the prompt), LlamaLogitsIntegrationTests.swift (the chat-template test calls it). This answers both findings of 2026-11-12 14:11.
    - test: green — integration 56 tests in 14 suites passed, 0 failed, 0 skipped. The root package did not change.
    - commit: aac88f3 test(integration): the chat-template logits test uses the shared row check
    - review: clean — `review sha eb47bc5..aac88f3`, 2 files, 0 findings. The swift tool rules again reported "found no file" (the tool reads the main checkout). To close that gap, `swiftlint lint` was run by hand on the new files: it reported 2 `nesting` violations in LlamaCppIntegrationTests.swift (the `Response` and `SplitSetLoad` structs). Iteration 3 moves them to file scope.
  timestamp: 2026-11-12T19:21:17.008727+00:00
- actor: claude-code
  id: 01m78v4x5zy300yp4vfwd5de4q
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — LlamaCppIntegrationTests.swift: `Response` and `SplitSetLoad` are private types at file scope (swiftlint `nesting`, found by a manual swiftlint run because the review tool rules cannot read the worktree files). The two findings of 2026-11-12 14:11 are ticked: aac88f3 fixed them. The fix is an overload `expectFiniteAndNotPositive(_:candidates:after:)`, because a default value of a parameter cannot be an async tokenizer call.
    - test: green — `swift test --package-path IntegrationTests` (run in a copy of the worktree in a folder named FoundationModelsExtras): 56 tests in 14 suites passed, 0 failed, 0 skipped. "MLX logits with a real model", "LlamaCpp logits with a real model" and "LlamaCpp loader with real models" passed. swiftlint on the new files: no violation. The root package did not change after iteration 1 (root `swift test` passed there).
    - commit: e2569f3 test(integration): the result types of the llama.cpp loader suite are at file scope
    - review: clean — `review sha aac88f3..e2569f3`, 1 file, 0 findings; all prior findings are ticked. Task moved to done.
    - open: the acceptance criterion "After the push, the CI job ... passes" cannot be checked before the push. Nothing was pushed.
  timestamp: 2026-11-12T21:38:15.871972+00:00
position_column: done
position_ordinal: ffe380
title: Move the env-gated real-model suites into the IntegrationTests package, so CI runs them
---
## What
CI runs real-model tests only from the nested package `IntegrationTests/`. `.github/workflows/ci.yml` says: "No input selects tests with an environment variable." `IntegrationTests/Package.swift` also says: "Nothing reads an environment variable to select tests." Three suites do not obey this rule. They read an environment variable, so CI always skips them:
- `Tests/FoundationModelsExtrasTests/ModelPool/MLXLogitsRealModelTests.swift` (`EXTRAS_MLX_INTEGRATION`, model `mlx-community/Qwen3-0.6B-4bit`)
- `Tests/FoundationModelsExtrasLlamaCppTests/LlamaLogitsRealModelTests.swift` (`EXTRAS_GGUF_INTEGRATION`, model `Mapika/decider-2b-GGUF`)
- `Tests/FoundationModelsExtrasLlamaCppTests/LlamaCppRealModelTests.swift` (`EXTRAS_GGUF_INTEGRATION`; this suite was there before the other two)

Move each suite into `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/`, and remove the environment gate.

- [x] Move `MLXLogitsRealModelTests.swift` to `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/MLXLogitsIntegrationTests.swift`. Remove the `.enabled(if:)` trait. The products that it needs (`FoundationModelsExtras`, `MLXFoundationModels`) are already dependencies of the integration target.
- [x] Move `LlamaLogitsRealModelTests.swift` and `LlamaCppRealModelTests.swift` to the same folder (`LlamaLogitsIntegrationTests.swift`, `LlamaCppIntegrationTests.swift`). Remove the gates. In `IntegrationTests/Package.swift`, add the dependency `git@github.com:swissarmyhammer/FoundationModelsLlamaCpp.git` (branch `main`, the same pin as the root package), and add the products `FoundationModelsExtrasLlamaCpp` (package `..`) and `FoundationModelsLlamaCpp` to the existing integration target. Give each new dependency a comment that tells which test needs it, the same as the other entries. If a moved suite uses `FixtureSupport` or `LlamaCppTestFixtures`, add only what it needs.
- [x] The llama tests need `swiftSettings: [.interoperabilityMode(.Cxx)]`. Add it to the existing integration target, and make sure that all the existing integration suites still compile and pass with it. Do not add a new target. If C++ interoperability prevents the existing suites from compiling, record the compiler error on this card and stop as stuck. A person must then decide about a second target.
- [x] Remove the moved files from the root test targets. In `Tests/FoundationModelsExtrasLlamaCppTests/`, keep `LlamaCppModelLoaderTests.swift` and `LlamaLogitsTests.swift`, which do not read an environment variable. Make sure that no file in `Tests/` or `Sources/` reads `EXTRAS_MLX_INTEGRATION` or `EXTRAS_GGUF_INTEGRATION`.
- [x] Docs: if `docs/REFERENCE.md`, `docs/GUIDE.md` or `README.md` name either variable, change the text to `swift test --package-path IntegrationTests`.

## Acceptance Criteria
- [x] `grep -rn "EXTRAS_MLX_INTEGRATION\|EXTRAS_GGUF_INTEGRATION" Sources Tests IntegrationTests docs README.md` finds nothing.
- [x] `swift test --package-path IntegrationTests` runs the MLX logits, llama logits and llama.cpp loader suites with no skips, and all their tests pass.
- [x] The root `swift test` passes, and it has no skip that comes from an environment variable.
- [x] `IntegrationTests/Package.swift` has one test target only, and the root `Package.swift` does not change.
- [ ] After the push, the CI job "Integration (opt-in, real dependencies)" runs the moved suites and passes.

## Tests
- [x] Run `swift test --package-path IntegrationTests`. All tests pass, and the log shows the moved suites.
- [x] Run `swift test` at the root. All tests pass.
- [x] Run the grep of the first acceptance criterion. It gives no result.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. For this move: first make the moved suites compile and run in the integration package, then remove the old files. #decision

## Review Findings (2026-11-12 14:11)

> Scope: `review sha ddf5bf7..eb47bc5` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 0 not reviewed.

> ⚠️ The tool rules `code-hygiene/disallowed-constructs-swift`, `code-hygiene/function-length-swift`, `code-hygiene/idioms-swift`, `code-hygiene/magic-numbers-swift` and `code-hygiene/missing-docs-swift` each declined an item: each "found no file at" IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/LlamaCppIntegrationTests.swift, LlamaLogitsIntegrationTests.swift, MLXLogitsIntegrationTests.swift and Support/LogitsChecks.swift, so these were unread by the tool rules.

- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/LlamaLogitsIntegrationTests.swift:63` `reuse/reuse` — The chat-template test repeats the checks of LogitsChecks.expectFiniteAndNotPositive: the row has the candidate count, and every value is finite and not more than 0. The helper does this for a fixed text prompt only. The test copies the logic and does not pass its prompt to the helper. Two copies of one check can drift apart. Give `LogitsChecks.expectFiniteAndNotPositive` a prompt parameter with the current `text` tokens as its default. Call it from `chatTemplatePromptGivesARow` with the rendered prompt and the candidates. Keep only the context-size check in the test body.
- [x] `IntegrationTests/Tests/FoundationModelsExtrasIntegrationTests/LlamaLogitsIntegrationTests.swift:64` `reuse/reuse` — The finite and not-positive check on the chat-template row is a second copy of the check in LogitsChecks. This is the same finding as line 63, reported on the second assertion line. Remove the inline assertion. Use the parameterized `LogitsChecks.expectFiniteAndNotPositive` described for line 63.