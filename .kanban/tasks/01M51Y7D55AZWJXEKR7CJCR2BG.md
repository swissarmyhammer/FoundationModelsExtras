---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51yvz15shqyzst83fg0y2r6
  text: |-
    ### review — clean
    - evidence: review sha 2935533..4820dfa; 2 files reviewed; 7 validator runs; 0 findings, 0 confirmed, 0 refuted, 0 failed.
    - next: none. The task is in done.
  timestamp: 2026-10-16T08:57:12.485008+00:00
- actor: claude-code
  id: 01m51ywqycbwanqx2p2fs5511q
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Elicitation.swift, ElicitationRelayTests.swift (8 new tests)
    - test: green — swift test, 1191 tests in 114 suites passed (one full run for E1 and E2 together)
    - commit: 4820dfa
    - review: clean — no findings
  timestamp: 2026-10-16T08:57:37.996742+00:00
position_column: done
position_ordinal: ff9980
title: 'E1: A question request keeps the path of the agents that relayed it, and its source tool'
---
## What

`ElicitationRequest` (`Sources/FoundationModelsExtras/OperationEvents/Elicitation.swift`) gets two new values, so that a parent session can relay the question of a subagent to the user and show where it came from.

- `public let agentPath: [String]`, default `[]`. The agents that relayed the question, from the agent nearest the user to the agent that asked. It is empty for a question that a run of this session asked.
- `public let source: String?`, default `nil`. The tool of the run that asked the question, at the level where the question was asked.
- `public func relayed(by agent: String, askedBy tool: String) -> ElicitationRequest`. It gives a copy with the same `elicitationId`, `agentPath = [agent] + agentPath`, and `source = source ?? tool`.
- Codable: encode each key only when it is not empty. A missing key decodes as `[]` or `nil`, so old transcripts decode.
- The two init methods get the two values as parameters with defaults. This is an additive change.

## Acceptance Criteria

- [x] A JSON request with no `agentPath` and no `source` key decodes with `[]` and `nil`.
- [x] A request with a path and a source encodes and decodes to an equal value.
- [x] A request with an empty path and no source encodes no `agentPath` key and no `source` key.
- [x] Two relays give the path in the correct order, keep the id, and keep the first source.

## Tests

Fixed-order Swift Testing tests in `Tests/FoundationModelsExtrasTests`. No clock, sleep, poll, retry or time limit.

#elicitation-phase-4