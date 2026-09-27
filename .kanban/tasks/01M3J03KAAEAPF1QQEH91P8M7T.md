---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3j3r8655yc2ds4shqy2dkzx
  text: |-
    ### finish iteration 1 — clean
    - implement: Added two tests to Tests/OperationsMacrosTests/OperationMacroTests.swift. The first test expands `@Operation` with no argument list. The result has no extension and no diagnostic. The second test is parameterized. It expands `@OperationParam` alone in 4 forms. Each form gives no peer declaration and no diagnostic. The tests use the `operationMacroSpecs` helper. A new `operationParamMacroSpecs` gives the spec for `@OperationParam`. No change to Sources.
    - test: `swift build --build-tests` passed with 0 compiler warnings (only the SwiftPM manifest-cache "disk I/O error" warnings). `swift test` passed: 1377 tests in all test runs, 0 failures.
    - commit: 7735af9 "test(operations): test @Operation with no argument list and the peer expansion of @OperationParam". The commit also has the kanban changes of task b0xcxvb.
    - review: `review sha HEAD~1..HEAD` gave 0 findings. The task moved to done.
  timestamp: 2026-09-27T18:59:00.933480+00:00
position_column: done
position_ordinal: d080
title: Add tests for @Operation with no argument list, and for the @OperationParam peer expansion
---
Sources/OperationsMacros/OperationsMacros.swift:431-433, 927-929

Coverage: 96.7% (412/426 lines)

Uncovered lines: 432, 927-929 (lines 935-938 are the `@main` plugin registration and do not need a test)

- `OperationMacro.expansion(of:attachedTo:providingExtensionsOf:conformingTo:in:)` (432): when the attribute has no argument list (`@Operation` with no parentheses), the expansion returns no extension.
- `OperationParamMacro.expansion(of:providingPeersOf:in:)` (927-929): the peer expansion returns no declarations. No test expands `@OperationParam` alone.

What to test (macro expansion tests in Tests/OperationsMacrosTests):
- `@Operation struct S {}` with no arguments expands to the struct with no added extension. Record the diagnostics that the expansion gives.
- `@OperationParam(...)` on a property expands to the property with no peer declaration. #coverage-gap

## Review Findings (2026-09-27 13:57)

Scope: `review sha HEAD~1..HEAD` (commit 7735af9). The review examined 1 file. It found 0 findings. There are no unchecked items.