---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52bg0519djkbdsaqa48ce7r
  text: |-
    ### review — clean
    - evidence: review sha 016c5a8..cd6162a; 4 files reviewed; findings 0, confirmed 0, refuted 1, attempted 7, failed 0, skipped 0. The task has no prior review findings.
    - next: The task is in done. No more work is necessary.
  timestamp: 2026-10-16T12:37:51.905961+00:00
- actor: claude-code
  id: 01m52bh19j1g0zzp2h98s6cd2h
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — BackgroundToolRunner.swift, RunPlaneActor.swift (internal token source), ToolRun.swift (envelope post that does not set run-plane progress), BackgroundDuplicateTokenTests.swift (4 new tests)
    - test: green — swift test, 1201 tests in 116 suites passed
    - commit: cd6162a
    - review: clean — no findings
  timestamp: 2026-10-16T12:38:25.842477+00:00
position_column: done
position_ordinal: ff9c80
title: A background call fails safely when the run plane refuses its run token as a duplicate
---
## What

`BackgroundToolRunner.start(arguments:)` (`Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift:144`) ignores the result of `RunPlane.start`. When the run plane gives `.duplicateToken`, the body never runs, but the call already posted the open record and the pending envelope under that token, and it then waits for a run that is the run of a different call. This cannot occur in practice, because each token is a new ULID, but the call must fail safely.

Accepted design:

1. Call `runPlane.start` before the call posts anything. The body first waits for a gate. The call posts the open record and the envelope, and then opens the gate. The gate also opens in a `defer` and in the cancel handler, so it opens on each exit path.
2. On `.duplicateToken`: post nothing under that token, write one error log line, and return `Answer(result: .failure(DuplicateRunTokenError), settledTerminal: nil)`. `DuplicateRunTokenError` is internal. No new public `ToolMountError` case. No `assertionFailure`.
3. An internal token source on `RunPlane`, so that a `@testable` test can give two calls the same token. The public init keeps a new ULID for each run.

Found in the work: because the run is on the run plane before the envelope post, the envelope post would set the progress detail of the run on the run plane. The envelope now goes through a funnel path that does not change that detail, so the run-plane list still shows the progress of the tool.

## Acceptance Criteria

- [x] Two background calls with the same token: the first is gated and open. The second, with grace 0, gets the error text, its body never runs, it posts no event and no record, and it writes one error log line. The first run then settles normally.
- [x] A cancel of the call between the start and the open of the gate: the body runs and settles, and no run stays open.
- [x] The duplicate-token test fails on the old code (it does not compile: no token source, no error type). The gate, envelope and cancel tests are guards of the new order, and they also pass on the old code.

## Tests

Fixed-order Swift Testing tests. No clock, sleep, poll, retry or time limit.

#bug