---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4gk88bmfvppd0xsa38nf7r4
  text: |-
    Research done.
    - ToolContext.post(display:) (from ^1vhftw2) sends to the sink of the context. In ContextBindingTool the sink is site.sink. In ToolRun (RunToCompletionRunner and BackgroundToolRunner) the sink is the RunEventFunnel of the run. Thus emit(chunk:) and update(title:kind:locations:) can be thin calls of post(display:), and all three paths get them.
    - RunEventFunnel.post(display:) does not change resetCount now. The timeout loop (waitForTimeout) compares resetCount before and after each window. Increase resetCount in post(display:) to make a display event a sign of life.
    - BackgroundToolRunner.start calls StagedEventWithdrawing.withdrawStagedEvents(correlationID:) on the session sink when the run ends in the settle period. The runner delivers each display event through the funnel before the run settles, so the client has it before the withdraw.
    - Decision (grace period): display events are NOT withdrawn. The withdraw exists so that the model does not read a result two times. The model never reads a display event, and the client already shows it. Document it on StagedEventWithdrawing, BackgroundToolRunner and ToolDisplayEvent.
    - Decision (timeout): a display event counts as a sign of life, the same as progress and a message. A tool that streams output is alive.
    - The CHANGELOG entry of ^1vhftw2 (Unreleased) says a display event "changes no timeout state". Correct that text.
  timestamp: 2026-10-09T15:07:06.996518+00:00
- actor: claude-code
  id: 01m4gkvtmcpjxtfr9cz99tmx6r
  text: |-
    Implementation landed (TDD).
    - RED 1: the new suite did not compile (`ToolContext` has no member `emit` / `update`).
    - GREEN 1: added `ToolContext.emit(chunk:)` and `ToolContext.update(title:kind:locations:)`. Both are thin calls of `post(display:)`. The path tests (ContextBindingTool, RunToCompletionRunner, BackgroundToolRunner in the settle period, BackgroundToolRunner after the settle period) and the grace-period test passed.
    - RED 2: the timeout test failed for the correct reason for both beat kinds: "display_beat_tool timed out after 0.5 seconds with no progress".
    - GREEN 2: `RunEventFunnel.post(display:)` now increases `resetCount`.
    - Decision 1 (timeout): a display event counts as a sign of life, the same as progress and a message. Documented on RunEventFunnel, ToolContext.post(display:), ToolDisplayEvent, ToolMount.timeout, CHANGELOG and README.
    - Decision 2 (settle period): a display event is NOT withdrawn. `StagedEventWithdrawing` applies only to staged operation events. The model never reads a display event, and the runner delivers each display event before the withdraw. The grace test records the display count at the withdraw call to prove this order. Documented on StagedEventWithdrawing, BackgroundToolRunner.start, ToolDisplayEvent, CHANGELOG and README.
    - The grace-period test passed on its first run: it records behavior that already existed (the funnel delivers each display event before the run settles). It is a contract test for the decision.
    - Corrected the Unreleased CHANGELOG entry of ^1vhftw2, which said that a display event "changes no timeout state".
    - Not changed: the text of `ToolMountError.timedOut` ("... with no progress"). A public-surface test asserts that exact text, and the card does not ask for a change.
    - Full suite: one run, exit 0. Swift Testing 913 tests in 87 suites pass (11 known issues are existing withKnownIssue tests in TelemetryCaptureTests). The only "warning:" line is a SwiftPM build-system message about the mlx-swift_Cmlx.bundle product, not about a source file.
  timestamp: 2026-10-09T15:17:48.300177+00:00
- actor: claude-code
  id: 01m4gkvxpbtj3natftv6r51h1k
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsExtras/Hosting/ToolContext.swift, Sources/FoundationModelsExtras/Hosting/ToolRun.swift, Sources/FoundationModelsExtras/Hosting/HostingSeams.swift, Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift, Sources/FoundationModelsExtras/Hosting/ToolMount.swift, Sources/FoundationModelsExtras/OperationEvents/ToolDisplayEvent.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolDisplayHelperTests.swift (new, 7 test cases), CHANGELOG.md, README.md. `swift test`: exit 0, 913 Swift Testing tests in 87 suites pass, 0 failures.
    - next: /review
  timestamp: 2026-10-09T15:17:51.435729+00:00
- actor: claude-code
  id: 01m4gm0xd87qmn5dv4xmkdghh5
  text: |-
    ### test — green
    - evidence: swift test — 913 tests in 87 suites passed, 0 failed. 11 known issues: these are the planned withKnownIssue checks in TelemetryCaptureTests. They prove the capture helper reports a forbidden string. They are not skips. One build-tool warning only (mlx-swift_Cmlx.bundle "missing creator for mutated node"). It does not come from the source. No source warning.
    - next: review
  timestamp: 2026-10-09T15:20:34.984946+00:00
- actor: claude-code
  id: 01m4gm1h7tnzaqkwbe3cnwjp0j
  text: |-
    ### commit — changed
    - evidence: d710d56 feat(hosting): add emit(chunk:) and update(title:kind:locations:) to ToolContext
    - next: none. The commit is local. It is not pushed.
  timestamp: 2026-10-09T15:20:55.290658+00:00
depends_on:
- 01M4GH3SXGTK24GQS301VHFTW2
position_column: doing
position_ordinal: '80'
title: Add emit(chunk:) and update(title:kind:locations:) on ToolContext
---
## Problem

Task ^1vhftw2 adds `ToolDisplayEvent` and `OperationEventSink.post(display:)`. A tool must have a simple API on `ToolContext` to send these events.

Terminals are out of scope. Do not add terminal support.

## Work

1. Add `ToolContext.emit(chunk:)`. It sends a `ToolDisplayEvent` with kind `.contentChunk`.
2. Add `ToolContext.update(title:kind:locations:)`. It sends a `ToolDisplayEvent` with kind `.metadata`.
3. Both methods must work in all of these paths (`Hosting/ToolMounting.swift:194-251`):
   - `ContextBindingTool`
   - `BackgroundToolRunner`
   - `RunToCompletionRunner`
4. Both methods must work in a background run after the grace period (`BackgroundToolRunner.swift:94-134`).
5. Decide if display events that are staged in the grace period are withdrawn the same as progress events. Document the decision.
6. A display event must count as a sign of life for the run timeout, the same as progress (`ToolContext.swift:198-202`, `ToolRun.swift:129-139`). If you decide that it must not count, document the reason.

## Tests

- Add a test for each runner path: `ContextBindingTool`, `BackgroundToolRunner` and `RunToCompletionRunner`.
- Add a test for a background run after the grace period.
- Add a test for the grace-period decision (withdrawn or not withdrawn).
- Add a test that a display event resets the run timeout, or a test for the documented behavior.

## Related

- Depends on ^1vhftw2 (Add a display-only event lane for tools).