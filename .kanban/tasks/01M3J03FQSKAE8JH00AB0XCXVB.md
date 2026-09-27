---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3j3fy3ew1d8twgtsbbw5q19
  text: |-
    ### finish iteration 1 — review clean

    - implement: Added one parameterized macro expansion test for `(Int, Int)` and for a property with no type annotation. The test examines the diagnostic ID. The test for `[String: Int]` was already there.
    - test: `swift build --build-tests` gives 0 compiler warnings. `swift test` passes 1375 tests (131 + 38 + 44 + 26 + 396 + 740).
    - commit: 54faa53 (the test file and the pending .kanban changes of ^6bcdaqq and ^b0xcxvb).
    - review: `review sha HEAD~1..HEAD` gives 0 findings (7 validators ran). The task moves to done.
  timestamp: 2026-09-27T18:54:28.462463+00:00
position_column: done
position_ordinal: cf80
title: Add tests for the @Operation diagnostics of an unsupported parameter type
---
Sources/OperationsMacros/OperationsMacros.swift:46-48, 179, 693-694

Coverage: 96.7% (412/426 lines)

Uncovered lines: 46-48, 179, 693-694

- `internal var diagnosticID: MessageID` (46-48): no test reads the diagnostic ID.
- `private func primitiveParamTypeExprText(_ type: TypeSyntax) -> String?` (179): a type that is not an array and not an identifier (for example a tuple, a function type or a dictionary) returns `nil`.
- `private func operationParameterEntry(for:identifierPattern:variable:in:)` (693-694): a stored property with no type annotation (for example `var count = 1`) gets the unsupported-type diagnostic.

What to test (macro expansion tests in Tests/OperationsMacrosTests):
- A parameter of type `(Int, Int)` and a parameter of type `[String: Int]` each give the `unsupportedParameterType` diagnostic.
- A stored property with no type annotation gives the `unsupportedParameterType` diagnostic.
- The diagnostic has the ID domain `OperationsMacros` and the ID `Operation.unsupportedParameterType(...)`. #coverage-gap

## Implementation notes

- The test `rejectedParameterProducesTheUnsupportedTypeDiagnosticWithItsID(_:)` in Tests/OperationsMacrosTests/OperationMacroTests.swift is parameterized. It examines `var pair: (Int, Int)` and `var count = 1`. Its `DiagnosticSpec` examines the message, the line, the column and the ID (domain `OperationsMacros`, ID `Operation.unsupportedParameterType("<name>")`).
- The test `structurallyUnsupportedDictionaryTypeProducesDiagnostic()` already examines `[String: Int]`. This change does not copy that test.
- A check with a wrong column made the new test fail. Thus the assertion is active.

## Review Findings (2026-09-27 13:52)

Scope: `review sha HEAD~1..HEAD` on commit 54faa53. 7 validators ran. 0 findings.
