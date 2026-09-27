---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3j1czrs3crvz5v3jsf21r5w
  text: |-
    ### analysis — a probable cause
    - The test drops its hold (`hold = nil`) and then submits an admit job. The hold came out of an admission job (`pool.acquire` → `admit` → `admissions.submit`).
    - Probable cause: code in `GenerationQueue` (the worker or the `Job`) keeps a reference to the result of the job for a short time after it resumes the caller. For example, a local `result` in the worker, or a result that the job state keeps. Then `hold = nil` does not release the last reference. The last reference goes on the worker thread later, so `release` and the eviction enqueue can come after the next admit job.
    - This is a real defect, not only a test defect: the time of the last release must be the time when the caller drops its hold.
    - Check this first: count the references, or put a log in `ModelHold.deinit` and in the worker. Then make the queue drop each reference to the result before, or in the same step as, the resume of the caller. Keep the code small; no new types.
  timestamp: 2026-09-27T18:17:54.713632+00:00
- actor: claude-code
  id: 01m3j2ct5hkxwca6jkrmqv7kdq
  text: |-
    ### finish iteration 1 — review clean
    - cause (confirmed with evidence): `Job.run` resumes the submitter with `continuation.resume(with:)`. That call only borrows the result. The job task keeps its own reference until the call returns. Thus `hold = nil` in the caller is not always the last release. A temporary log in `ModelHold.deinit` showed that 39 of 200 deinit calls ran on the detached job task, after the resume. 18 of 200 test runs failed. A new unit test failed at once before the fix. The temporary logs are removed.
    - implement: `Job.Resume` takes `consuming Result`. The job calls `resume(consume result)`. The resume in `submit` moves the value into `continuation.resume(returning:)`. No new types, locks or sleeps. New test in GenerationQueueWorkerTests: "the result of an item is released at once when its submitter drops it" (1000 repetitions).
    - test: `swift build --build-tests` has 0 compiler warnings (only the SwiftPM manifest cache disk I/O warnings). `swift test --filter ModelPoolTests` passed 10 of 10 runs (13 tests each). `swift test`: 1372 tests pass (131, 37, 44, 26, 396, 738). `swift test --package-path IntegrationTests`: 22 tests pass. The only warning is "missing creator for mutated node … mlx-swift_Cmlx.bundle".
    - commit: bc47b26 fix(model-pool): move the job result into the continuation, so the caller has the last reference (includes the pending .kanban changes of ^zvh3hh0).
    - review: `review sha HEAD~1..HEAD`: 0 findings. Task moves to done.
  timestamp: 2026-09-27T18:35:17.553049+00:00
position_column: done
position_ordinal: cc80
title: 'ModelPoolTests: the test "an admit job submitted at once after the last release runs after the eviction" fails some of the time'
---
`swift test --filter ModelPoolTests` fails in some runs at Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift:273 with "Expectation failed: residentInTheJob.isEmpty".

Evidence (2026-09-27): at commit 9c4840e (no change to ModelPool), 1 run of 6 failed. With the work of task ^zvh3hh0, 3 runs of 5 failed. The failure is in the code or the test of commit c7691c0 (the eviction job and the admission queue).

What to do: find the race between the last release, the eviction job and a later admission job, and make the order certain.

## Review Findings (2026-09-27 13:33)

Scope: `review sha HEAD~1..HEAD` (bc47b26). 7 validator passes, 0 findings, 0 confirmed, 0 failed. The review tool did not examine the `.kanban/` files (`.reviewignore`).

- [x] No findings.