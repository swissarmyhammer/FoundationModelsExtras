---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4r1bcj547k73sk9d1dtw28a
  text: 'Research: `RunPlane.start` calls `Self.runTraced`, which calls `TracedCall.run` with no tracer, thus `InstrumentationSystem.tracer`. `TracedCall.run` already takes `tracer: (any Tracer)? = nil` and uses `tracer ?? InstrumentationSystem.tracer`. Plan: add `tracer: (any Tracer)? = nil` to `RunPlane.start` (SPI call shape stays), give it to `runTraced` and to `TracedCall.run`, and pass `site.tracer` from `BackgroundToolRunner.start(arguments:)`. Test goes in `ToolCallSpanTests.swift` with `MountFixtures` and a `W3CInMemoryTracer` site tracer. The existing test `aBackgroundStartGivesItsMetrics` covers the path with no session tracer.'
  timestamp: 2026-10-12T12:28:10.693923+00:00
- actor: claude-code
  id: 01m4r1k20kzzzzjdmqvsks4k5q
  text: 'Implementation done (TDD). RED: new test `aBackgroundCallRecordsBothSpansOnTheSessionTracer` in ToolCallSpanTests found only `FoundationModelsExtras.tool` on the site tracer. GREEN: `RunPlane.start` has a new `tracer: (any Tracer)? = nil` parameter. The parameter goes to `runTraced` and then to `TracedCall.run(tracer:)`. `BackgroundToolRunner.start(arguments:)` passes `site.tracer`. The SPI call shape stays the same (the default is nil), and `RunPlaneTestingSPIPublicSurfaceTests` still compiles without a change to its call. I also updated the DocC symbol link in that file and in `StartResult` to `start(tool:op:kind:completionToken:canceler:tracer:body:)`. `MountFixtures.site` and `backgroundHarness` have a new optional `tracer` parameter, so the test does not make a local copy of the site. The run span now has the trace id of the tool span (seen in the enter log). The existing test `aBackgroundStartGivesItsMetrics` covers the path with no session tracer. Full `swift test`: 1007 tests in 90 suites passed. The 11 known issues are the expected `withKnownIssue` cases in TelemetryCaptureTests. The only warning is the mlx-swift `missing creator for mutated node` line. I did not touch the 8 files of ^kaghnvn.'
  timestamp: 2026-10-12T12:32:22.035774+00:00
- actor: claude-code
  id: 01m4r1k4es57tve49ym1tt6ryq
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift, Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift, Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneTestingSPIPublicSurfaceTests.swift; `swift test` 1007 tests passed, 0 failed
    - next: /review
  timestamp: 2026-10-12T12:32:24.537663+00:00
- actor: claude-code
  id: 01m4r1stj5brhg2kycwgx1nqtx
  text: |-
    ### review — clean
    - evidence: review sha 5b2b146~1..5b2b146 — 0 findings (0 confirmed, 0 refuted); 5 source and test files reviewed; 4 .kanban files not reviewed (.reviewignore)
    - next: none. The task is in done.
  timestamp: 2026-10-12T12:36:03.781044+00:00
- actor: claude-code
  id: 01m4r1svmexpre7kvwxbehxcb5
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files
    - test: green — swift test, 1007 passed; IntegrationTests ToolHosting, 8 passed
    - commit: 5b2b146
    - review: clean — 0 findings
  timestamp: 2026-10-12T12:36:04.878185+00:00
depends_on:
- 01M4NXXX8C2BZAAK141DW9063W
position_column: done
position_ordinal: f680
title: 'Run plane span: record the run body span with the session tracer of the mount site'
---
## What

`RunPlane.start(tool:op:kind:completionToken:canceler:body:)` opens the `FoundationModelsExtras.run` span (task ^dw9063w) with `InstrumentationSystem.tracer` at call time. `BackgroundToolRunner` opens the tool span with `site.tracer`, the tracer of the session. When a host gives a session tracer and binds no task-local tracer, the tool span goes to the session tracer and the run span goes to the global tracer. The two spans then go to different backends.

Approach:
- Give `RunPlane.start` an optional tracer (or give the run plane the tracer of its session), and pass `site.tracer` from `BackgroundToolRunner.start(arguments:)`.
- Keep the `@_spi(Testing)` call shape of `start` for the tests, with `nil` as the default.

## Acceptance Criteria
- [x] A background call on a site with a session tracer records the tool span and the run span on that tracer.
- [x] With no session tracer, the run span uses `InstrumentationSystem.tracer`, as now.

## Tests
- [x] A test in `Tests/FoundationModelsExtrasTests/Hosting/` with a `W3CInMemoryTracer` given as the site tracer and no `withTracer`: both spans are in that tracer.
- [x] `swift test` passes with no warnings.

#telemetry