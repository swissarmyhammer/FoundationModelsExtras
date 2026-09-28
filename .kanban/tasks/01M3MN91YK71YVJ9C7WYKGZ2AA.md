---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mrt2teaawngqc0sx9xm7rs
  text: |-
    Research (implement, iteration 1):
    - Task D (^91jnmp) is not done, but task A made `Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift`. The orchestrator said to put the constants of this task there. Thus the message prefix and the metadata keys go into `ExtrasTelemetry.EnterRecord`.
    - The generic Tracing API (swift-distributed-tracing 1.5.0) gives no trace id and no span id on `Span`. The only generic path is `Instrument.inject` into a carrier. swift-otel injects the W3C `traceparent` field. `InMemoryTracer` injects `in-memory-trace-id` / `in-memory-span-id` only. Decision: the helper injects the span context into a dictionary carrier and reads the ids from a W3C `traceparent` value. With `InMemoryTracer` the record has no ids ("when the span context gives them"). A test tracer that wraps `InMemoryTracer` and injects `traceparent` proves the id path.
    - `TelemetryCapture.run` binds its tracer with `withTracer`, so `InstrumentationSystem.tracer` inside the capture is the capture tracer. The test "one span and one enter record" passes no tracer and finds the span in `context.spans`, which proves the fallback.
    - The existing `BoundedWait` helper polls with `Task.sleep`. The hang test does not use it: it waits on an `AsyncStream` that a log handler yields to, and the suite `.timeLimit(.minutes(1))` is the bound.
    - Log level decision: `.info`, because `.info` is the default level of a swift-log logger, so the record reaches the backend with no configuration.
  timestamp: 2026-09-28T19:45:29.934303+00:00
- actor: claude-code
  id: 01m3ms993jvxk12jg0741yax07
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/Telemetry/TracedCall.swift (new), Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift (EnterRecord vocabulary), Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift (new). `swift build --build-tests`: no errors, no warnings. `swift test --skip-build --filter 'FoundationModelsExtrasTests\.(TracedCallTests|SpanIdentityTests|ExtrasTelemetryTests|TelemetryCaptureTests)'`: 17 tests in 4 suites passed.
    - notes: the metadata of the record holds only the caller metadata plus `trace.id` and `span.id` (the card says "holds only"), so no `span.name` key; the span name is in the message. The helper is `nonisolated(nonsending)` so that `body` runs on the actor of the caller, the same as `TelemetryCapture.run`. The test target has no `InMemoryLogging` dependency, so the tests compare the fields of the records and not `InMemoryLogHandler.Entry` values.
    - next: /test
  timestamp: 2026-09-28T19:53:47.890842+00:00
- actor: claude-code
  id: 01m3msc69hwk34f0ntns6p097c
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — Swift Testing runs: 764 tests in 77 suites passed (4 known issues, all the expected `withKnownIssue` cases of TelemetryCaptureTests), plus 396, 131, 44, 40 and 26 tests in the other test products, 0 failed, 0 skipped; build output has 0 warnings.
    - next: /commit
  timestamp: 2026-09-28T19:55:23.313459+00:00
- actor: claude-code
  id: 01m3msptxr9d17ekyac34ajj8z
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 736820a): 4 findings, 4 confirmed, 0 refuted — TracedCall.swift:163, :164, :165, :166 `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
    - next: /implement to fix every finding
  timestamp: 2026-09-28T20:01:12.120149+00:00
- actor: claude-code
  id: 01m3mspx3wg39026vhx7v9s5tz
  text: |-
    ### finish iteration 1 — findings
    - implement: changed (TracedCall.swift, ExtrasTelemetry.swift, TracedCallTests.swift)
    - test: green (`swift test --parallel`, 0 failed, 0 skipped, 0 warnings)
    - commit: 736820a feat(telemetry): add TracedCall, which opens a span and writes one enter log record
    - review: 4 findings — TracedCall.swift:163-166 `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
  timestamp: 2026-09-28T20:01:14.364295+00:00
- actor: claude-code
  id: 01m3msv0avqe7zwh9nv8td7b11
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsExtras/Telemetry/TracedCall.swift: the four field lengths of `SpanIdentity.Field.length` (2, 32, 16, 2) are now the named constants `versionLength`, `traceIDLength`, `spanIDLength` and `flagsLength`. No other unnamed numeric literal stays in the file.

    ### test — green
    - evidence: `swift test --parallel` — 764 tests in 77 suites passed (4 expected known issues), plus 396, 131, 44, 40 and 26 tests in the other products; 0 failed, 0 skipped, 0 warnings. The TracedCall and SpanIdentity suites passed.
    - next: /commit
  timestamp: 2026-09-28T20:03:28.731630+00:00
depends_on:
- 01M3MN838VZ4QX57C3965XMGKV
- 01M3MN8N9P4RPET2V5JZ6JQD9G
position_column: doing
position_ordinal: '80'
title: 'OTel C: add a shared helper that opens a span and writes one "enter" log record, for hang detection'
---
## What

Part C of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 8, hang detection: a backend exports a span only when the span ends. Thus a call that hangs gives no span. A span on a call that can suspend for a long time must also write one "enter" log record when it starts. Multitool and other packages will use this helper.

Add a public helper in the core target, in a new file `/Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Sources/FoundationModelsExtras/Telemetry/TracedCall.swift` (the name is a proposal):

- [x] An API like `TracedCall.run<Output>(_ spanName: String, ofKind: SpanKind = .internal, tracer: (any Tracer)? = nil, logger: Logger, attributes: (inout SpanAttributes) -> Void = { _ in }, metadata: Logger.Metadata = [:], _ body: (any Span) async throws -> Output) async throws -> Output`. It opens the span with `tracer ?? InstrumentationSystem.tracer`, sets the attributes, writes one log record at `.debug` or `.info` level (decide, and document it) with the message `enter <spanName>` and metadata that holds only `metadata` plus the trace id and the span id of the new span (when the span context gives them), and then runs `body`. It writes nothing more on exit; the span records the end and the error.
- [x] The log record must carry no content: the helper takes only the metadata that the caller gives, and it does not put `body` values or errors into the message. Document rule 4 on the API.
- [x] Put the log message text and the metadata keys (for example `span.name`, `trace.id`, `span.id`) in the Extras vocabulary file of task D if that file exists; if not, put them in a small `enum` in this file and let task D move them.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] One call gives one finished span with the given name and attributes, and exactly one log record that the helper wrote before `body` started.
- [x] The "enter" record is written even when `body` never returns during the test (the test cancels `body` after it sees the record).
- [x] A thrown error from `body` is recorded on the span and rethrown; the helper writes no second log record.

## Tests
- [x] New `Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift`: use the `TelemetryTestSupport` capture from task B. Tests: (1) one span and one "enter" record, and the record comes before the body runs (the body checks the captured records); (2) a body that waits on a continuation that the test never resumes: the test waits for the "enter" record with a bounded wait on a real signal, then cancels the task; (3) a throwing body; (4) the helper passes the content-safety check of task B with a forbidden string given to `body` only.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.

## Review Findings (2026-09-28 14:55)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsExtras/Telemetry/TracedCall.swift:163` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsExtras/Telemetry/TracedCall.swift:164` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsExtras/Telemetry/TracedCall.swift:165` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsExtras/Telemetry/TracedCall.swift:166` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.