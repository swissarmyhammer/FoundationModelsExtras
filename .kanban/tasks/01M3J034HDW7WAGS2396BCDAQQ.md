---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Add tests for BackgroundToolRunner.canceler(of:) with a canceler that is not a process canceler
---
Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift:107-114

Coverage: 98.3% (59/60 lines)

Uncovered lines: 112

`private func canceler(of run: ToolRun<Arguments>) -> (@Sendable () async -> OperationOutcome)?`

The function gives the canceler of a background tool. When the tool gives a canceler and its `runKind` is not `.process`, the function returns the canceler of the tool directly (line 112). The tests cover only the `.process` path and the path with no canceler.

What to test (through the public mount API, not the private function):
- A background tool with `runKind` that is not `.process` and that gives `canceler(forCompletionToken:)`. Cancel the run. The canceler of the tool runs one time, and the run settles with the outcome that the canceler returns. #coverage-gap