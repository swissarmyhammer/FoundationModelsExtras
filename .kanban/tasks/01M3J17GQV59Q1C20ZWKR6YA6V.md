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
position_column: doing
position_ordinal: '80'
title: 'ModelPoolTests: the test "an admit job submitted at once after the last release runs after the eviction" fails some of the time'
---
`swift test --filter ModelPoolTests` fails in some runs at Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift:273 with "Expectation failed: residentInTheJob.isEmpty".

Evidence (2026-09-27): at commit 9c4840e (no change to ModelPool), 1 run of 6 failed. With the work of task ^zvh3hh0, 3 runs of 5 failed. The failure is in the code or the test of commit c7691c0 (the eviction job and the admission queue).

What to do: find the race between the last release, the eviction job and a later admission job, and make the order certain.