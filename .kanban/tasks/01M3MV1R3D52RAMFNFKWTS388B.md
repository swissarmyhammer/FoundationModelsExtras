---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'OTel E: TelemetryCapture uses a tracer that records spans and injects and extracts W3C traceparent and tracestate'
---
## What

Request from the swissarmyhammer-05 session (2026-09-28). ACPAgent tasks 6, 7 and 8, ACPClient task A, Multitool OTel 4 and 5, and Router task D need this task.

Problem: `TelemetryCapture` (`/Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Tests/TelemetryTestSupport/TelemetryCapture.swift`, lines 88, 102 and 120) binds an `InMemoryTracer` with `withTracer`. `InMemoryTracer` injects and extracts only its own trace-id and span-id keys. It does not inject or extract a W3C `traceparent`. Thus:
- In a capture, the "enter" record of `TracedCall.run` (`Sources/FoundationModelsExtras/Telemetry/TracedCall.swift`) has no `trace.id` and no `span.id`, because `SpanIdentity` reads the ids from `traceparent` (TracedCall.swift:189–212).
- No package can test that `traceparent` goes across ACP `_meta` or MCP request `_meta` (rule 7 of the OTel design).

A start exists: the private `TraceparentTracer` in `Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift:264–353` wraps an `InMemoryTracer` and injects `traceparent`, but it does not extract, and it has no `tracestate`.

Work:
- [ ] Add a public tracer to `TelemetryTestSupport`, for example `W3CInMemoryTracer` in `Tests/TelemetryTestSupport/W3CInMemoryTracer.swift`. It records the spans like `InMemoryTracer` (the same finished-span access that `TelemetryCapture.Context` gives now). `inject` writes `traceparent` (`00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`) and `tracestate` when the context has one. `extract` reads `traceparent` and `tracestate`, refuses a value that the W3C format does not allow, and puts the remote span context into the `ServiceContext`, so that the next span that starts in that context is a child with the same trace id.
- [ ] Make `TelemetryCapture` bind this tracer by default. Change the type of `Context.tracer` (or add a protocol or an option) so that current users still compile; update the users in this package. Record the API change in `CHANGELOG.md`.
- [ ] Remove the private `TraceparentTracer` from `TracedCallTests.swift`, and use the new tracer.
- [ ] Use `SpanIdentity` or the W3C constants in `ExtrasTelemetry` for the field names, so that there is one copy of the `traceparent` format. If `SpanIdentity` must be public for this, make it public with doc comments.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] Inside `TelemetryCapture.run`, the "enter" record of `TracedCall.run` holds the `trace.id` and the `span.id` of its span.
- [ ] An inject into a carrier and then an extract from that carrier give back the same trace id, and a span that starts in the extracted context is a child of the injected span (same trace id, parent span id = the injected span id).
- [ ] `tracestate` goes through an inject and an extract with no change.
- [ ] An invalid `traceparent` gives no remote context, and the next span starts a new trace.

## Tests
- [ ] New `Tests/FoundationModelsExtrasTests/Telemetry/W3CInMemoryTracerTests.swift`: inject format; inject then extract gives the same trace id and a child span; `tracestate` round trip; invalid `traceparent` values (a parameterized test).
- [ ] Update `Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift`: a test that runs `TracedCall.run` in `TelemetryCapture.run` with no explicit tracer, and checks the ids on the enter record.
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.
- Do not implement this task until the user says so. #otel