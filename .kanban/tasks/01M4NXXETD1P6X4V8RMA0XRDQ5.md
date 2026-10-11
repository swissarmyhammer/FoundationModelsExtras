---
assignees:
- claude-code
depends_on:
- 01M4NXRKC72JZA6WNSS7752WAG
position_column: todo
position_ordinal: '8380'
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
- [ ] `Mailbox()` compiles with no change at each call site. A caller can give a `ModelRef`. The queue name is always `mailbox`.
- [ ] Each letter records `queue.wait`, `queue.run` and one `queue.tasks` count when it completes, with `queue.name=mailbox` and the correct `queue.outcome`.
- [ ] A letter that is cancelled before a batch takes it records a wait time, no run time, and `cancelled`.
- [ ] A letter that `cancel(_:)` removes from `running` records its run time and `cancelled`, exactly one time.
- [ ] The depth meter goes up at `post` and goes back to 0 when each letter has its answer or its cancel.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift`: with `MetricsTestKit` `TestMetrics` through `withMetricsFactory`, test the depth values, the timers and the dimensions (with and without a `ModelRef`) for a batch that succeeds, a batch that fails, a cancel before start, and a joined letter from `takeJoining`.
- [ ] A test that cancels a running letter: it records `cancelled` with a run time, and the depth goes back to 0 after the cancel.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` from `Tests/TelemetryTestSupport/TelemetryCapture.swift`, with a message text that must not show. The test also asserts that the capture saw at least one metric.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature