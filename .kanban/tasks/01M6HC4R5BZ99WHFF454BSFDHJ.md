---
assignees:
- claude-code
position_column: todo
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