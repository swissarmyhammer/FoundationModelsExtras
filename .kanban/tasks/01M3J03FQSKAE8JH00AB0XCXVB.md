---
assignees:
- claude-code
position_column: review
position_ordinal: '80'
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