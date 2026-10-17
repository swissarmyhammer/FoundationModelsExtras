---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54smdqfee3pr1svcmbt29fe
  text: 'Added to the scope: the real mount timeouts in ProcessRunnerTests (for example aCommandThatPassesTheTimeoutGivesTheTimeoutResultAndTheGroupIsGone and the grandchild kill test, which use Self.shortTimeout). Use the same rule: first find out if the ProcessRunner timeout takes an injected clock. Change Sources only after the peer session reviews the place and the proposed change.'
  timestamp: 2026-10-17T11:23:25.807418+00:00
- actor: claude-code
  id: 01m54x22rr55an2d7tnnp7wcrk
  text: |-
    Research:
    - The mount timeout (ToolRun, RunEventFunnel.waitForTimeout) and the settle grace (BackgroundToolRunner.start, RunPlane.wait) wait on RunPlane.clock. No Sources change for them. Only the fixtures change: runToCompletionHarness gets a runPlane parameter, as backgroundHarness has.
    - ProcessRunner.run does not take an injected timer: it calls waitOrKill with ChildControl.system, whose sleep is Task.sleep. The peer approved a Sources change: an internal run(...) that takes control: ChildControl, and the public run keeps its signature and calls it with .system. No public API change.
    - RunPlane.settle resumes each wait of the run with .settled, and only then gives the terminal to the BackgroundRunSettlementObserver. Thus, after the observer got the terminal, a clock move cannot change the answer of the runner. The C tests use that order: wait until the call ends or the observer gets the terminal, then move the clock past the grace, then read the call. A runner that misses the settle ends at the deadline with the envelope, and the test fails at once.
    - Limit, the same for B and C: a call that sets no timer and never ends, or a run that never settles, gives no event. Each test then has no end event. The peer accepted this limit for the ProcessRunner tests.
    - theDurationCoversTheWholeRun stays as it is (a lower bound only), as the peer decided.
  timestamp: 2026-10-17T12:23:19.064012+00:00
- actor: claude-code
  id: 01m54xnc2j9x9hsxts87g5mxve
  text: |-
    ProcessRunner part done (commits 38b3d0f Sources refactor, be219c7 tests).
    - 38b3d0f: an internal ProcessRunner.run(... control: ChildControl). The public run keeps its signature and calls it with .system. No public API change, no behavior change on the .system path.
    - be219c7: aCommandThatPassesTheTimeoutGivesTheTimeoutResultAndTheGroupIsGone and aChildOfTheChildIsAlsoKilledBecauseTheKillGoesToTheGroup use StandInTimer (ChildControl.system with only sleep replaced). The test fires the timer when the child gave its pid through the named pipe. On a throw, the timer fires and the test waits for the run, so the runner kills the group and reaps the child (the test sends no kill itself, because a kill after the reap can reach a reused pid). Before: 500 ms real timeout each. After: 0.009 s each.
    Fault demos (one run each, then git checkout -- Sources):
    1. Sources fault: in waitOrKill, `_ = processGroup.kill(); timedOut = false`. Both tests failed at once (0.010 s): "Expectation failed: outcome.termination == .timedOut".
    2. Test fault: StandInTimer.fire() does nothing (the timer never fires). Both tests failed after 60.03 s, at the end of the child sleep, with "the child ended with .exited(code: 0), not at the timeout". The grandchild test also failed on the marker file. No hang.
    EXCEPTION (accepted by the peer): Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift:263 (aCommandThatPassesTheTimeoutGivesTheTimeoutResultAndTheGroupIsGone) and :278 (aChildOfTheChildIsAlsoKilledBecauseTheKillGoesToTheGroup). When the timer never fires or the kill never goes out, the test ends only at the end of the child sleep (60 s). Reason: the entry of the stand-in sleep and the pid handshake have no fixed order, thus "the stand-in was not entered" is never a final fact, and the only other end event is the end of the child. The grandchild wait in the second test (exits(grandchild)) has the same property.
  timestamp: 2026-10-17T12:33:51.186334+00:00
- actor: claude-code
  id: 01m54yatk8rk6dktshgd9p51g9
  text: |-
    Runner suites done (commits 370e0c8, d85b108).
    B (mount timeouts, 7 tests): RunToCompletionRunnerTests perCallTimeoutOverridesMount, nilPerCallTimeoutFallsBackToMount, timeoutExpiryThrowsNamedError, timeoutSetsCancellationFlag; BackgroundToolRunnerTests timeoutExpiryOnBackgroundRun; ToolCallSpanTests aTimedOutCallIsNotAnError, aBackgroundRunThatTimesOutInlineIsNotAnError. Each call waits on a ManualRunClock. The test moves the clock to one step before the timeout (the timer must still wait), then the last step (the timer must end). Before: each test waited 0.2 s of real time.
    C (settle grace, 17 tests): BackgroundToolRunnerTests toolWithNoGraceFollowsTheSite, defaultSiteGraceSettlesAFastRunInline, statedGraceWinsOverTheSite, runSettlingInsideTheGraceAnswersWithItsOwnOutput, runThrowingInsideTheGraceRethrowsTheToolError, inlineResultWithdrawsWhatTheRunStaged, inlineErrorWithdrawsWhatTheRunStaged, runCancelledInsideTheGraceGivesAToolResult, cancelledCallOfACancelledRunThrowsTheCancellation; ToolDisplayHelperTests backgroundToolRunnerDeliversTheDisplaysInTheSettlePeriod, inlineAnswerDoesNotWithdrawTheDisplays; ToolCallSpanTests aBackgroundRunThatSucceedsInlineRecordsSucceeded, aBackgroundCallRecordsBothSpansOnTheSessionTracer, aBackgroundRunThatFailsInlineRecordsFailed, aBackgroundRunThatTimesOutInlineIsNotAnError, aBackgroundRunThatTheSweepSettlesRecordsTheRunPlaneOutcome, aBackgroundCallCarriesNoToolContent. Each call runs on ManualSettlePlane (RunPlaneTestSupport.swift). The wait ends when the call ends or the settlement observer gets the terminal; then the clock moves past the grace. The sweep test moves the clock after sweep() returns, because the sweep resumes each wait before it returns.
    Green run: 68 tests in the 4 suites passed after 0.006 s.
    Fault demos (one run each, then git checkout -- Sources, no hang in each run):
    1. ToolRun.swift waitForTimeout: window = seconds * 2. All 7 B tests failed in 0.005 s ("no timer ended at 0.2 seconds").
    2. BackgroundToolRunner.start: the call sleeps to the deadline and never answers from the settlement (always the envelope). 16 of 17 C tests failed in 0.004 s. aBackgroundCallRecordsBothSpansOnTheSessionTracer passed: it checks the tracer route, not the settle.
    3. BackgroundToolRunner.callInBackground: tracer nil in place of site.tracer. aBackgroundCallRecordsBothSpansOnTheSessionTracer failed in 0.002 s.
    EXCEPTION (accepted by the peer), same class as the ProcessRunner one: in each B and C test, a call that sets no timer and never ends, or a run that never settles in a call that never ends, gives no end event, so the wait does not end. Reason: the start of the timer and the start of the settle wait have no fixed order with an event that the test can see, so "no timer came" is never a final fact.
  timestamp: 2026-10-17T12:45:34.184441+00:00
- actor: claude-code
  id: 01m54ym3ffgq9vby8kc7f6fnkn
  text: |-
    Extra sites (scope added by the peer). Commit 6431835.
    Changed (background call with a settle grace on a real-clock run plane, now on ManualSettlePlane):
    - ToolContextMountTests settlingWithinChangesTheGraceOfInnerMounts (grace 30 s). makeHost takes a run plane.
    - ToolHostingPublicSurfaceTests aRunInsideTheGraceAnswersWithItsOwnOutput (grace 30 s).
    - HoldingRunTokenTests aRunGivesItsOwnToken, synchronousInnerCallsGiveTheRunToken, aNestedSynchronousCallGivesTheRunToken, aBackgroundInnerCallGivesItsOwnToken, twoRunsGiveDifferentValues (grace 3600 s).
    Green: 8 tests passed after 0.004 s. Fault demo (the call never answers from the settlement, one run, then git checkout -- Sources): all 7 changed tests failed in 0.003 s, no hang; aHostContextGivesItsOwnToken (not changed, synchronous only) passed.
    Checked, not changed:
    - ToolHostingReadmeTests.swift:44 readmeBackgroundToolExample: the code is the README example (README.md:927 shows `let runPlane = RunPlane()`); a correct runner has no real-time wait, and only a broken runner waits the 6 s grace. The peer chose to keep it.
    - ToolContextMountTests contextCarriesTheConfiguredSettlePeriod, ToolHostingPublicSurfaceTests aHostSetsTheSettlePeriodOnTheContext, HoldingRunTokenTests aHostContextGivesItsOwnToken, ToolContextTests (FastTool mounts), ToolFailureDeliveryTests: no background call.
    - DeclaredRunKindTests, ToolHostingPublicSurfaceTests (other background calls), OperationMountTests, ToolContextMountSinkPublicSurfaceTests, PerCallMountTests: grace 0, the call answers with the envelope at once.
    - ToolContextMountTests innerCallInsideTheOuterSettlePeriodKeepsTheReserve, innerCallAfterTheOuterDeadlineWaitsItsFullGrace, RunClockTests settlePeriodFollowsTheClock: already on a manual clock.
  timestamp: 2026-10-17T12:50:38.191034+00:00
- actor: claude-code
  id: 01m54yq9sh3d6b5cs7ph9fp6cp
  text: |-
    ### implement — changed
    - evidence: commits 38b3d0f (Sources: internal ProcessRunner.run with control), be219c7 (ProcessRunnerTests), 370e0c8 (RunPlaneTestSupport, MountFixtures, RunToCompletionRunnerTests), d85b108 (BackgroundToolRunnerTests, ToolDisplayHelperTests, ToolCallSpanTests), 6431835 (ToolContextMountTests, ToolHostingPublicSurfaceTests, HoldingRunTokenTests). One full root `swift test`: 1223 tests in 120 suites passed after 8.818 s; 410 in 29 suites; 131, 40, 44, 26 in the other targets; 0 failures. The one build warning ("missing creator for mutated node ... mlx-swift_Cmlx.bundle") comes from SwiftPM for the mlx bundle and is not from these changes. No public API change. Siblings: FoundationModelsSkills ShellInjection.swift:261 and RunScript.swift:265 call the public ProcessRunner.run, whose signature and behavior did not change.
    - next: /review
  timestamp: 2026-10-17T12:52:22.961026+00:00
depends_on:
- 01M53BTZ0M0DH3HXBD47N7BNKZ
position_column: doing
position_ordinal: '80'
title: 'Tests: the mount timeouts and the settle grace use a manual clock, not the real clock'
---
## Goal

Remove the real-clock time waits that stay in Tests/ after ^7n7bnkz. No test may use a clock, sleep, poll, retry or time limit.

## Scope

1. Mount timeouts that really elapse (0.2 s):
   - RunToCompletionRunnerTests: 4 tests that use Fixtures.shortInterval.
   - BackgroundToolRunnerTests: timeoutExpiryOnBackgroundRun.
   - ToolCallSpanTests: 2 tests.
   First, find out if the mount timeout and the run-to-completion timeout already take an injected clock, as RunPlane.wait does. If yes, the tests use ManualRunClock and advance it. If a Sources change is necessary to inject a clock, stop. Send the place and the proposed change to the peer session before you make the change.
2. The 30 s settle grace (Fixtures.generousInterval) on a real-clock plane. If the gate fails, this grace is a time limit. About 10 tests in BackgroundToolRunnerTests, ToolDisplayHelperTests and ToolCallSpanTests.
   Use a ManualRunClock plane. Then the grace does not elapse unless the test advances the clock. The wait ends on the settle event or on the failure event.

## Order

Start this card after ^7n7bnkz is done. Do it before the card that shares the model loads.

## Acceptance

- No test in this list waits on the real clock.
- Each changed test fails on wrong code, and it does not hang. The card records how this was shown.
- One full local run passes. CI passes.