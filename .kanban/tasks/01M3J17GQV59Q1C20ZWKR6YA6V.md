---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: 'ModelPoolTests: the test "an admit job submitted at once after the last release runs after the eviction" fails some of the time'
---
`swift test --filter ModelPoolTests` fails in some runs at Tests/FoundationModelsExtrasTests/ModelPool/ModelPoolTests.swift:273 with "Expectation failed: residentInTheJob.isEmpty".

Evidence (2026-09-27): at commit 9c4840e (no change to ModelPool), 1 run of 6 failed. With the work of task ^zvh3hh0, 3 runs of 5 failed. The failure is in the code or the test of commit c7691c0 (the eviction job and the admission queue).

What to do: find the race between the last release, the eviction job and a later admission job, and make the order certain.