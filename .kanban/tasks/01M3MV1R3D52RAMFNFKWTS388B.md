---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mv9p6xpbwb6mmkrzm6chty
  text: |-
    Research (implement, iteration 1):
    - `InMemoryTracer` (swift-distributed-tracing 1.4.x) is a struct with a locked state box. It injects and extracts only `in-memory-trace-id` and `in-memory-span-id`. A child span copies the parent `ServiceContext`, thus a value that the tracer puts in the context (for example `tracestate`) goes to each child span.
    - `InMemoryTracer(idGenerator:)` accepts closures for the ids. The W3C tracer gives it random lowercase hex ids of 32 and 16 digits.
    - No other package of the family uses `TelemetryCapture.Context.tracer` now (rg over /Users/wballard/github/swissarmyhammer). In this package, `ToolCallSpanTests` gives `context.tracer` as `any Tracer`, and `TelemetryCapture.run` binds it with `withTracer`.
    - `TelemetryTestSupport` does not depend on `FoundationModelsExtras` now. To keep one copy of the `traceparent` format, the plan adds that dependency and makes `SpanIdentity` public, in its own file.
    - With the new tracer, the enter record in a capture holds `trace.id` and `span.id`. Thus `TracedCallTests.oneCallGivesOneSpanAndOneEnterRecord` must expect the ids.
    - The core `DictionaryInjector` is private in TracedCall.swift. The plan exposes `SpanIdentity.injectedFields(of:by:)`, so that the test support uses the same injector.
  timestamp: 2026-09-28T20:28:58.461982+00:00
- actor: claude-code
  id: 01m3mvsqyyndg295ywzsxpkwze
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsExtras/Telemetry/SpanIdentity.swift (new, public), Sources/FoundationModelsExtras/Telemetry/TracedCall.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Tests/TelemetryTestSupport/W3CInMemoryTracer.swift (new), Tests/TelemetryTestSupport/TelemetryCapture.swift, Tests/FoundationModelsExtrasTests/Telemetry/W3CInMemoryTracerTests.swift (new), Tests/FoundationModelsExtrasTests/Telemetry/SpanIdentityTests.swift (new, moved from TracedCallTests.swift), Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift, Package.swift, CHANGELOG.md. `swift build --build-tests` has no compile warning. `swift test --skip-build --filter 'FoundationModelsExtrasTests\.(W3CInMemoryTracerTests|SpanIdentityTests|TracedCallTests|TelemetryCaptureTests|ToolCallSpanTests|ExtrasContentSafetyTests|ExtrasTelemetryTests|TelemetryDependencyTests)'`: 52 tests in 8 suites passed (4 known issues of the existing withKnownIssue tests).
    - notes: `Context.tracer` is now `W3CInMemoryTracer`; the old `InMemoryTracer` is at `context.tracer.inMemoryTracer`. The tracer also validates `tracestate` (member count, key and value format) and keeps the trace flags in `ServiceContext.w3cTraceFlags`. The SwiftPM "failed loading cached manifest: disk I/O error" warnings come from the environment cache, not from the code.
    - next: /test
  timestamp: 2026-09-28T20:37:44.542928+00:00
- actor: claude-code
  id: 01m3mvxg2eyys8d0gp97xadmes
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — 792 tests in 79 suites passed, 0 failed, 0 skipped, 4 known issues (the expected issues of the existing withKnownIssue tests in TelemetryCaptureTests); 0 compiler warnings (only the SwiftPM manifest-cache "disk I/O error" warnings of the environment). Filtered run `swift test --filter 'FoundationModelsExtrasTests\.(W3CInMemoryTracerTests|SpanIdentityTests|TracedCallTests|...)'`: 52 tests ran.
    - next: /commit
  timestamp: 2026-09-28T20:39:47.534502+00:00
- actor: claude-code
  id: 01m3mwaypem77jhh7myds8qkj2
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 53c797f) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 9 files reviewed; .kanban (ignore rule) and CHANGELOG.md (no validator) not reviewed. No prior Review Findings sections.
    - next: task moved to done
  timestamp: 2026-09-28T20:47:08.494776+00:00
- actor: claude-code
  id: 01m3mwb0bfwhth34f5v65xtd3g
  text: |-
    ### finish iteration 1 — clean
    - implement: changed (10 files); test: green (`swift test --parallel` 792 tests in 79 suites passed, 0 failed, 0 skipped); commit: 53c797f; review: clean (`review sha HEAD~1..HEAD`, 0 findings).
    - task moved to done.
  timestamp: 2026-09-28T20:47:10.191478+00:00
position_column: done
position_ordinal: d680
title: 'OTel E: TelemetryCapture uses a tracer that records spans and injects and extracts W3C traceparent and tracestate'
---
## What

Request from the swissarmyhammer-05 session (2026-09-28). ACPAgent tasks 6, 7 and 8, ACPClient task A, Multitool OTel 4 and 5, and Router task D need this task.

Problem: `TelemetryCapture` (`/Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Tests/TelemetryTestSupport/TelemetryCapture.swift`, lines 88, 102 and 120) binds an `InMemoryTracer` with `withTracer`. `InMemoryTracer` injects and extracts only its own trace-id and span-id keys. It does not inject or extract a W3C `traceparent`. Thus:
- In a capture, the "enter" record of `TracedCall.run` (`Sources/FoundationModelsExtras/Telemetry/TracedCall.swift`) has no `trace.id` and no `span.id`, because `SpanIdentity` reads the ids from `traceparent` (TracedCall.swift:189–212).
- No package can test that `traceparent` goes across ACP `_meta` or MCP request `_meta` (rule 7 of the OTel design).

A start exists: the private `TraceparentTracer` in `Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift:264–353` wraps an `InMemoryTracer` and injects `traceparent`, but it does not extract, and it has no `tracestate`.

Work:
- [x] Add a public tracer to `TelemetryTestSupport`, for example `W3CInMemoryTracer` in `Tests/TelemetryTestSupport/W3CInMemoryTracer.swift`. It records the spans like `InMemoryTracer` (the same finished-span access that `TelemetryCapture.Context` gives now). `inject` writes `traceparent` (`00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`) and `tracestate` when the context has one. `extract` reads `traceparent` and `tracestate`, refuses a value that the W3C format does not allow, and puts the remote span context into the `ServiceContext`, so that the next span that starts in that context is a child with the same trace id.
- [x] Make `TelemetryCapture` bind this tracer by default. Change the type of `Context.tracer` (or add a protocol or an option) so that current users still compile; update the users in this package. Record the API change in `CHANGELOG.md`.
- [x] Remove the private `TraceparentTracer` from `TracedCallTests.swift`, and use the new tracer.
- [x] Use `SpanIdentity` or the W3C constants in `ExtrasTelemetry` for the field names, so that there is one copy of the `traceparent` format. If `SpanIdentity` must be public for this, make it public with doc comments.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] Inside `TelemetryCapture.run`, the "enter" record of `TracedCall.run` holds the `trace.id` and the `span.id` of its span.
- [x] An inject into a carrier and then an extract from that carrier give back the same trace id, and a span that starts in the extracted context is a child of the injected span (same trace id, parent span id = the injected span id).
- [x] `tracestate` goes through an inject and an extract with no change.
- [x] An invalid `traceparent` gives no remote context, and the next span starts a new trace.

## Tests
- [x] New `Tests/FoundationModelsExtrasTests/Telemetry/W3CInMemoryTracerTests.swift`: inject format; inject then extract gives the same trace id and a child span; `tracestate` round trip; invalid `traceparent` values (a parameterized test).
- [x] Update `Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift`: a test that runs `TracedCall.run` in `TelemetryCapture.run` with no explicit tracer, and checks the ids on the enter record.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`. #otel