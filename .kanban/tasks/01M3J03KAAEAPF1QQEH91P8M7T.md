---
assignees:
- claude-code
position_column: review
position_ordinal: '80'
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