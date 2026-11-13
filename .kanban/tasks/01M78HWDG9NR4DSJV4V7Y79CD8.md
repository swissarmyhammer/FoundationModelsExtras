---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m797apf8pkn0hjjrqnmtmjev
  text: |-
    Research: Tests/FoundationModelsExtrasLlamaCppTests/ has three files: LlamaCppModelLoaderTests.swift (the GGUF loader), LlamaLogitsTests.swift (the PooledLogits conformance: tokenizer, chat template, prompt limit), LlamaDecisionsTests.swift (the PooledDecisions conformance: decision type and the maps). All three use the vocab-only GGUF files of LlamaCppTestFixtures and load no weights. No Swift file in the repository reads EXTRAS_GGUF_INTEGRATION; only the stale comment had it. The new comment names the three areas and tells that the real-model GGUF tests are in IntegrationTests/ (`swift test --package-path IntegrationTests`). The root `swift test` boxes stay open for the test step.

    ### implement — changed
    - evidence: 1 file — Package.swift (comment of the FoundationModelsExtrasLlamaCppTests target only). `grep -n "EXTRAS_GGUF_INTEGRATION" Package.swift` finds nothing (exit 1). `swift build`: Build complete (one SwiftPM build-system warning "missing creator for mutated node" for mlx-swift_Cmlx.bundle, not from this change).
    - next: test (root `swift test`), then review.
  timestamp: 2026-11-13T01:11:08.520467+00:00
- actor: claude-code
  id: 01m797ggbnvq48bgw5prs8xe2t
  text: |-
    ### review — clean
    - evidence: review sha 25e087b~1..25e087b. 0 findings (findings 0, confirmed 0, refuted 0, attempted 7, failed 0). Package.swift was reviewed. The two .kanban/ files were not reviewed because .reviewignore excludes them. The task had no prior Review Findings section.
    - next: none. The task moved to done.
  timestamp: 2026-11-13T01:14:18.869562+00:00
- actor: claude-code
  id: 01m797h111wynk4qzpta2yzx6w
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Package.swift (one comment)
    - test: green — swift test, 2531 passed, 0 failed
    - commit: 25e087b
    - review: clean — 0 findings
  timestamp: 2026-11-13T01:14:35.937362+00:00
depends_on:
- 01M77TPTFW0730ECSJ2TTSAZW2
position_column: done
position_ordinal: ffe580
title: Correct the stale comment of the FoundationModelsExtrasLlamaCppTests target in the root Package.swift
---
## What
The comment above the `FoundationModelsExtrasLlamaCppTests` test target in the root `Package.swift` says: "The one test of a real model runs only when `EXTRAS_GGUF_INTEGRATION` is `1`." The real-model GGUF suites moved to the nested package `IntegrationTests/`, and no test reads that variable now. The comment is thus wrong.

- [x] Change the comment so that it tells only about the hermetic tests of the target, and tells that the real-model GGUF tests are in `IntegrationTests/` (`swift test --package-path IntegrationTests`).

## Acceptance Criteria
- [x] `grep -n "EXTRAS_GGUF_INTEGRATION" Package.swift` finds nothing.
- [x] The root `swift test` passes.

## Tests
- [x] Run the root `swift test`. All tests pass.