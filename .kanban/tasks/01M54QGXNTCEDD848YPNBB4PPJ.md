---
assignees:
- claude-code
depends_on:
- 01M53BTZ0M0DH3HXBD47N7BNKZ
position_column: todo
position_ordinal: '8180'
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