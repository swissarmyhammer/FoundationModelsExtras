---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hjmk05hq6hh67g0kn10t57
  text: |-
    ### implement — changed
    - evidence: files Sources/Operations/AnyOperation.swift, OperationError.swift, OperationTool.swift, Tests/OperationsTests/CoreTypesTests.swift. RED: 3 of 4 new tests failed (cancel, lost, unwrapped). GREEN: swift test filter OperationsTests|OperationsCLITests|OperationsMacrosTests|NotesToolTests passes (135, 40, 44, 26 tests), no warnings from this change.
    - callers: OperationTool.call catches only decodingFailed, so a cancel or lost error now passes through. No other caller or test expects the wrapped form of these two errors. OperationsCLI, Notes example and the other packages only use executionFailed for other errors.
    - next: review. No commit, no push.
  timestamp: 2026-11-03T20:47:00.613067+00:00
position_column: doing
position_ordinal: '8180'
title: An operation that throws CancellationError ends cancelled, and LostRunError ends lost
---
Defect, verified in the code: `AnyOperation.run` (Operations/AnyOperation.swift, the catch around `operation.execute(in:)`) wraps every error in `OperationError.executionFailed(cause:)`. Nothing unwraps it. The outcome rule `OperationOutcome.init(thrown:)` (used by ToolRun) sees the wrapper, so a body that throws CancellationError or LostRunError ends the run as failed. No operation body can end a run as cancelled or lost.

Fix, test first:
- In `AnyOperation.run`, rethrow CancellationError and any LostRunError as they are. Keep every other error wrapped in `executionFailed(cause:)`.
- Update the doc comments of AnyOperation.run, OperationTool and OperationError that describe the wrapping.
- Tests: an operation that throws CancellationError ends cancelled; one that throws LostRunError ends lost; any other error stays executionFailed and ends failed.
- Check the callers for assumptions about the wrapped form: OperationTool, BackgroundToolRunner, the run plane, and other packages in this repo.

Scope: do not mix with the failure value task (01M6HA3B670G61TZ115SGX9DAA) or the transcript task. Its files are in the working tree, uncommitted. Commit this fix on its own path set only.