---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50sse0akkcnm63jwv21g9qw
  text: |-
    Research. `RunPlane.completeAccepted` removes the question, calls `finish` (telemetry, then `answer.fulfill`), and only then starts the completion task. `Promise.fulfill` is synchronous, so on the old code the answer is given before the completion post starts. The answer wait is not cancellable, and the cooperative canceler returns at once, so a run cancel or a sweep while the completion post is held does not end the run: the run waits for the accept.

    A direct order test cannot fail with certainty on the old code: the resumed run and the completion task race on the global executor. A sink gate alone also cannot tell "the run is slow" from "the run is blocked" with no clock. The only synchronous witness of "the answer was given" is the elicitation queue telemetry: `finish` records the depth decrement before `fulfill`. The order test uses that witness with a `TestMetrics` factory to decide if the test opens the gate (new code) or leaves it to the run's own post (old code). Then the sink order differs in a deterministic way.

    The cancel and sweep tests (asked by the coordinator) pass on the old code too, because the old code resumes the run before the cancel comes. They guard the new order: the question left the list, so the cancel and the sweep do not give it a second answer.
  timestamp: 2026-10-15T22:09:12.202215+00:00
- actor: claude-code
  id: 01m50t6k32taws73gt8ndepwv8
  text: |-
    ### implement — changed
    - evidence: 4 files. Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift (completeAccepted: one task awaits `completing()` and then calls `finish`, so the telemetry record and the accept come one time and after the post; docs of complete, awaitAnswer, cancel, sweep), Sources/FoundationModelsExtras/OperationEvents/OperationEventSink.swift (doc of post(elicitationCompleted:)), Tests/FoundationModelsExtrasTests/Hosting/ElicitationSignalling.swift (SignallingSink gets an optional completion gate, and the signals completionHeld and progress), Tests/FoundationModelsExtrasTests/Hosting/ElicitationCompletionEventTests.swift (3 new tests).
    - RED (old code, `swift test --filter ElicitationCompletionEventTests`): 11 tests, 2 failed. The order test failed at `!answeredWhileHeld` and at the order check: history `[progress("after"), completed(id)]`. The sweep test failed too (`sweep().count == 1` gave 0, because the old code resumed the run before the sweep, so the run settled by itself). The run-cancel test passed on the old code.
    - GREEN (same filter): 11 of 11 passed.
    - Full `swift test`: 1156 tests in 112 suites passed, 0 failures.
    - Warnings: one only, `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, from the build system. It was in the RED build before the production change, so it is not new.
    - Not done by order of the coordinator: commit and push (fourth subtask stays open for the push and the head).
    - next: /review
  timestamp: 2026-10-15T22:16:23.394841+00:00
- actor: claude-code
  id: 01m50td9awwepmgtekh3redaya
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (9b25b98). 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. 4 files reviewed. 2 .kanban files not reviewed (ignore rule).
    - next: The task is in done. The subtask "One full test run" is not checked. The test step must do the full test run, push, and report the head.
  timestamp: 2026-10-15T22:20:02.780690+00:00
- actor: claude-code
  id: 01m50tdqsehmc4zfwq6te95dp1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files
    - test: green — swift test, 1156 passed (the one full run of the implement step); RED shown first: the order test and the sweep test failed on the old code
    - commit: 9b25b98
    - review: clean — 0 findings
    - push: follows this comment
  timestamp: 2026-10-15T22:20:17.582517+00:00
position_column: done
position_ordinal: ff9580
title: Post the completion of a URL flow before the run resumes
---
When an accepted URL flow completes, the run plane resumes the run first and posts the completion after that. The first posts of the resumed run can then reach the session sink before the completion, and a host cannot order them.

Rule: the completion is posted before the run resumes, with no wait for a clock.

- [x] Keep `RunPlane.complete(elicitationId:)` synchronous, with no change to its signature. It takes the question from the list at once (a second complete gives `.noPendingElicitation`), and it returns at once.
- [x] One task posts the completion, and only after that post resumes the run with the accept.
- [x] A fixed-order test: the resumed run posts at once, and the sink sees the completion first. The test fails on the old code. No clock, sleep, poll, retry or time limit.
- [ ] One full test run. The change is additive. Push when green, and report the head.

#elicitation-phase-3