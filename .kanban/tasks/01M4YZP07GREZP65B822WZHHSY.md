---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4z96725v9hnm37811bat6ab
  text: |-
    Research:
    - `ProcessRunner.waitOrKill` races a reap task (blocking `waitpid`) against a timer task (`Task.sleep`). On `.timedOut` the loop sends `killpg(pid, SIGKILL)`. When the reap task already finished `waitpid` but the loop takes `.timedOut` first, the kill goes to a reaped pid.
    - In Multitool the reap comes after the body ends, so its close is `killAndClose()` before the reap. In Extras the reap task blocks in `waitpid` until the child ends, so a close before that `waitpid` would also stop the timeout kill. Plan: split the reap. `waitid(P_PID, pid, WEXITED | WNOWAIT)` waits for the end of the child and leaves it a zombie (the pid stays reserved). Then the reap path closes the right, and only then `waitpid` reaps. A kill before the close goes to a zombie leader, which is safe.
    - The close sends no kill (unlike Multitool `killAndClose`): on a normal end Extras does not kill the group today, and this task does not change that.
    - The `.timedOut` result becomes "the kill went out" (`kill()` returns true). A timer that fires after the close gives the termination of the reap.
    - Seams for the test: an internal `ProcessRunner.ChildControl` with awaitExit, reap, sleep, signalGroup and a `timerWillSignal` hook (as Multitool `cancelerWillSignal`). Public API stays the same.
  timestamp: 2026-10-15T07:59:50.853772+00:00
- actor: claude-code
  id: 01m4z9bf8xtde5mwv7n908126e
  text: 'RED: added the internal seam `ProcessRunner.ChildControl` with the old order (no right to kill), and two tests in ProcessRunnerTests. `swift test --filter ProcessRunnerTests`: 17 tests, 2 issues. "aTimerThatFiresAfterTheReapStartedSendsNoKill": Expectation failed: kills.pids.isEmpty, "the timer sent a kill to [4242] after the reap of the child started". "aTimerThatFiresAfterTheReapStartedGivesTheTerminationOfTheReap": termination → .timedOut. Fixed order without sleeps: the stand-in reap finishes a stream that the stand-in timer waits on, and the reap does not return until the `timerWillSignal` hook ran. The build also prints "warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle"; this is a SwiftPM build-graph message about the mlx bundle, not a compiler warning of this change.'
  timestamp: 2026-10-15T08:02:43.101721+00:00
- actor: claude-code
  id: 01m4z9k2zrytfbj1p47rkmp3p8
  text: 'GREEN: added internal `ProcessGroupKill` (Sources/FoundationModelsExtras/ProcessGroupKill.swift): a Mutex-held right; `kill()` sends under the lock and returns false after `close()`. `waitOrKill` now makes one right per child. The reap task calls `awaitExit` (`waitid` with `WEXITED | WNOWAIT`, the child stays a zombie and its pid stays reserved), then `close()`, then `waitpid`. The timer path sets `timedOut = processGroup.kill()`, so a late timer sends nothing and the result is the termination of the reap. The EINTR loop of `waitid` and `waitpid` is one helper, `retryingInterrupts`. Public API is the same; only the doc text of `Failure.waitFailed` now names `waitid` too. `swift test --filter ProcessRunnerTests`: 17 tests passed. Full `swift test`: 1157 tests in 107 suites passed, exit 0. The only warning in the output is the SwiftPM build-graph line "missing creator for mutated node ... mlx-swift_Cmlx.bundle", which comes before this change and is not from the compiler.'
  timestamp: 2026-10-15T08:06:52.664607+00:00
- actor: claude-code
  id: 01m4z9k51kc8kn0cf2zczmtey9
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/ProcessGroupKill.swift (new), Sources/FoundationModelsExtras/ProcessRunner.swift, Tests/FoundationModelsExtrasTests/ProcessRunnerTests.swift. RED: `swift test --filter ProcessRunnerTests` 17 tests, 2 issues (kill sent to [4242]; result .timedOut). GREEN: same filter 17/17 passed. Full `swift test`: 1157 tests in 107 suites passed.
    - next: /review
  timestamp: 2026-10-15T08:06:54.771758+00:00
- actor: claude-code
  id: 01m4z9w1v67p700vy1vxfk9f5x
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 8882b46). 0 findings, 0 confirmed, 0 refuted. 3 files reviewed. 4 .kanban files not reviewed because of .reviewignore.
    - next: none. The task moved to done.
  timestamp: 2026-10-15T08:11:46.406897+00:00
- actor: claude-code
  id: 01m4z9w9c39hpm6tqnkqr53gt4
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files
    - test: green — swift test, 1157 passed (the full run of the implement step); RED shown first with the filtered ProcessRunnerTests run
    - commit: 8882b46
    - review: clean — 0 findings
  timestamp: 2026-10-15T08:11:54.115531+00:00
position_column: done
position_ordinal: ff8c80
title: ProcessRunner.waitOrKill can send killpg to a process group after waitpid reaped the child
---
## Defect

`ProcessRunner.waitOrKill` (Sources/FoundationModelsExtras/ProcessRunner.swift:196-221) can send `killpg` after `waitpid` reaped the child.

The timeout timer can fire after the reap. Then the signal goes to the pid of a reaped process. The system can give that pid to an unrelated process, so the signal can stop a process that is not ours.

## Known fix

FoundationModelsMultitool fixed the same race in its `ShellRunner` (commit a3f57c2). It uses a right to kill that a lock holds (`ProcessGroupKill`):

- The code that reaps the child closes the right before the reap.
- After the close, a kill sends nothing.

## Fix

- [x] Apply the same rule to `ProcessRunner.waitOrKill`: a lock-held right to kill, which the reap path closes before it calls `waitpid`.
- [x] Add a test with a fixed order of events (the reap closes the right, then the timer fires). No signal may reach a real process. The test must fail on the old code.
- [x] Do not use sleeps or timing loops in the test.

Found by Multitool step 5.

Do not start this task before the user or the coordinating session gives the order. #defect