---
assignees:
- claude-code
depends_on:
- 01M4NXXX8C2BZAAK141DW9063W
position_column: todo
position_ordinal: '9580'
title: 'Run plane span: record the run body span with the session tracer of the mount site'
---
## What

`RunPlane.start(tool:op:kind:completionToken:canceler:body:)` opens the `FoundationModelsExtras.run` span (task ^dw9063w) with `InstrumentationSystem.tracer` at call time. `BackgroundToolRunner` opens the tool span with `site.tracer`, the tracer of the session. When a host gives a session tracer and binds no task-local tracer, the tool span goes to the session tracer and the run span goes to the global tracer. The two spans then go to different backends.

Approach:
- Give `RunPlane.start` an optional tracer (or give the run plane the tracer of its session), and pass `site.tracer` from `BackgroundToolRunner.start(arguments:)`.
- Keep the `@_spi(Testing)` call shape of `start` for the tests, with `nil` as the default.

## Acceptance Criteria
- [ ] A background call on a site with a session tracer records the tool span and the run span on that tracer.
- [ ] With no session tracer, the run span uses `InstrumentationSystem.tracer`, as now.

## Tests
- [ ] A test in `Tests/FoundationModelsExtrasTests/Hosting/` with a `W3CInMemoryTracer` given as the site tracer and no `withTracer`: both spans are in that tracer.
- [ ] `swift test` passes with no warnings.

#telemetry