---
assignees:
- claude-code
depends_on:
- 01M77TPTFW0730ECSJ2TTSAZW2
position_column: todo
position_ordinal: '8380'
title: Correct the stale comment of the FoundationModelsExtrasLlamaCppTests target in the root Package.swift
---
## What
The comment above the `FoundationModelsExtrasLlamaCppTests` test target in the root `Package.swift` says: "The one test of a real model runs only when `EXTRAS_GGUF_INTEGRATION` is `1`." The real-model GGUF suites moved to the nested package `IntegrationTests/`, and no test reads that variable now. The comment is thus wrong.

- [ ] Change the comment so that it tells only about the hermetic tests of the target, and tells that the real-model GGUF tests are in `IntegrationTests/` (`swift test --package-path IntegrationTests`).

## Acceptance Criteria
- [ ] `grep -n "EXTRAS_GGUF_INTEGRATION" Package.swift` finds nothing.
- [ ] The root `swift test` passes.

## Tests
- [ ] Run the root `swift test`. All tests pass.