---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4pbf29jwy2jxq9qcea8s5wr
  text: |-
    Picked up. Research:
    - `QueueTelemetry` (Telemetry/QueueTelemetry.swift) gives `enqueued()` -> `QueueTicket`, `started(&ticket)` (sets the instant only, records no metric), and `completed(ticket, outcome:)` (depth down, wait, run when started, one count). It uses the factory of the ticket.
    - `GenerationQueue` makes the ticket before its lock, records completion outside the lock and before the submitter resumes. Its private `Job.outcome(of:)` maps a value to `succeeded`, `CancellationError` to `cancelled`, and each other error to `failed`.
    - Plan: the mailbox keeps a private `Entry` (letter + ticket) in `waiting` and `running`. The ticket is made in `post` before the lock. `nextBatch` and `takeJoining` call `started` under the lock (no metric). `answerNextBatch`, `cancel` and `deinit` call `completed` after the lock, before `fulfill`.
    - A batch body that throws `CancellationError` (the pump is cancelled while the body runs) gives `cancelled`, as in `GenerationQueue`. To share that rule, move `Job.outcome(of:)` to `QueueOutcome.init(of:)` in QueueTelemetry.swift, and call it from both queues.
    - Tests use `MetricsTestKit` `TestMetrics` and `QueueMetricDimensions.queue(named:model:)`.
  timestamp: 2026-10-11T20:46:28.146198+00:00
- actor: claude-code
  id: 01m4pc44pdwc8sngfy4ynh4c0s
  text: |-
    Implementation landed (TDD: the new suite failed first to compile because `Mailbox(model:)` did not exist, then all 9 tests passed).
    - Mailbox.swift: a private `Entry` (letter + `QueueTicket`) is in `waiting` and `running`. `post` makes the ticket before the lock. `nextBatch` and `takeJoining` set the start instant under the lock (no metric there). `answerNextBatch`, `cancel` and `deinit` call one private `finish(_:with:)` after the lock: it records the completion, then fulfills the letter. Each entry leaves the state one time, thus it completes one time.
    - `public init(model: ModelRef? = nil)` replaces `public init()`. `Mailbox()` still compiles at each call site (the README example test proves it).
    - QueueTelemetry.swift: new `QueueOutcome.init(of:)`. It is the old private `Job.outcome(of:)` of GenerationQueue, moved so both queues share one rule. GenerationQueue now calls it. Thus a batch body that throws `CancellationError` records `cancelled`, as in GenerationQueue. A test covers this case.
    - README Mailbox section: one bullet about the queue metrics and `Mailbox(model:)`. NOTE: a parallel session committed README.md in 7742182 (task ^pb1qp92 work) while this task ran, and that commit holds this bullet. The bullet is correct for this task, but it is in a commit of another task.
    - Full `swift test`: 964 Swift Testing tests in 90 suites passed, 11 known issues (the `withKnownIssue` tests of TelemetryCaptureTests, from before this task). Only warning: the mlx-swift `missing creator for mutated node ... mlx-swift_Cmlx.bundle` line from the dependency build.

    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/ModelPool/Mailbox.swift, Sources/FoundationModelsExtras/Telemetry/QueueTelemetry.swift, Sources/FoundationModelsExtras/ModelPool/GenerationQueue.swift, Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift, README.md (already in commit 7742182); `swift test --filter MailboxTelemetryTests` 9/9 pass; `swift test` 964 tests pass
    - next: /review
  timestamp: 2026-10-11T20:57:58.733305+00:00
- actor: claude-code
  id: 01m4pcpdcekp68grv6h44v8cam
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit f3469aa) — 0 findings, 0 confirmed, 1 refuted; 4 source files reviewed, 4 .kanban files not reviewed (.reviewignore)
    - next: none — the task is in done
  timestamp: 2026-10-11T21:07:57.454371+00:00
- actor: claude-code
  id: 01m4pcpegqjqk69dakebv5ckbq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files
    - test: green — swift test, 964 passed
    - commit: f3469aa
    - review: clean — 0 findings
  timestamp: 2026-10-11T21:07:58.615543+00:00
depends_on:
- 01M4NXRKC72JZA6WNSS7752WAG
position_column: done
position_ordinal: ef80
title: 'Queue metrics: Mailbox records depth and task timing for each letter'
---
## What

`Mailbox` (`Sources/FoundationModelsExtras/ModelPool/Mailbox.swift:16`, a public generic class) is a queue, but it records no metric. No code in this repo uses it now, but other packages of the family can use it. Connect it to the shared `QueueTelemetry` recorder of task `w9g6hm8`.

Approach:
- The queue name of a mailbox is always `QueueName.mailbox`. `QueueName` is internal (task `w9g6hm8`), thus a public init cannot take it, and a free `String` name from a caller would give a metric dimension with no limit. Add one optional public init parameter `model: ModelRef? = nil`, which gives the `model.ref` dimension. Keep `public init()` (`:50`) so that the public API does not break. The init makes the `QueueTelemetry` inside.
- One letter is one queue task. Keep the `QueueTicket` of each letter in the locked state, next to the letter.
  - `enqueued` at `post(_:)` (`:64`). `postAndWait(_:)` (`:81`) calls `post`, so it records one task only.
  - `started` when a batch takes the letter: `takeJoining(admitting:)` (`:142`), the private `nextBatch(isolation:joining:)` (`:199`), which `answerNextBatch` (`:168`) calls.
  - `completed` with `succeeded` or `failed` when the letter gets its answer.
  - `completed` with `cancelled` for `cancel(_:)` (`:95`) of a letter that did not start, and for each waiting letter that the deinit gives `CancellationError`.
  - `cancel(_:)` also removes a letter from `running` (the `cancelledInSubmission` branch). In that branch, also record `completed(.cancelled)`, with the run time of the letter.
- The depth is the count of letters in the queue plus the letters in the running batch.
- Make the metric objects with the factory that the `QueueTicket` keeps (task `w9g6hm8`). Add no telemetry string literal outside `ExtrasTelemetry.swift`. Never record the message or the answer.

## Acceptance Criteria
- [x] `Mailbox()` compiles with no change at each call site. A caller can give a `ModelRef`. The queue name is always `mailbox`.
- [x] Each letter records `queue.wait`, `queue.run` and one `queue.tasks` count when it completes, with `queue.name=mailbox` and the correct `queue.outcome`.
- [x] A letter that is cancelled before a batch takes it records a wait time, no run time, and `cancelled`.
- [x] A letter that `cancel(_:)` removes from `running` records its run time and `cancelled`, exactly one time.
- [x] The depth meter goes up at `post` and goes back to 0 when each letter has its answer or its cancel.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift`: with `MetricsTestKit` `TestMetrics` through `withMetricsFactory`, test the depth values, the timers and the dimensions (with and without a `ModelRef`) for a batch that succeeds, a batch that fails, a cancel before start, and a joined letter from `takeJoining`.
- [x] A test that cancels a running letter: it records `cancelled` with a run time, and the depth goes back to 0 after the cancel.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` from `Tests/TelemetryTestSupport/TelemetryCapture.swift`, with a message text that must not show. The test also asserts that the capture saw at least one metric.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature