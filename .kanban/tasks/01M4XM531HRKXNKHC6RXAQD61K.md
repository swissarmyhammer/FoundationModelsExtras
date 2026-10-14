---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xp3nj1p5jdz13j9ckaryqc
  text: |-
    Research:
    - TelemetryCapture is in Tests/TelemetryTestSupport (a library product), not in Sources/.
    - Log records: LogRecordStore.append is the one write path. It can resume the waits after the append.
    - Spans: InMemoryTracer makes each InMemorySpan with an internal onEnd closure. No hook is available. W3CInMemoryTracer can give the code a front span with its own onEnd. That onEnd copies the finished state to the InMemoryTracer span, ends it, and then resumes the waits. Thus inMemoryTracer.finishedSpans stays the same.
    - Metrics: TestMetrics is a final class with no hook. The capture can bind a front factory with withMetricsFactory. The front factory makes the metric in TestMetrics and wraps the handler, so that each made metric and each recorded value resumes the waits. A metric that the code makes directly with context.metricsFactory (a TestMetrics) goes past the front factory. Thus Context also gets a public observedMetricsFactory to give to code explicitly.
    - All consumer expect* calls in the sibling packages use a label, not a metric value. Thus a wrapped handler does not break them.
    - Pattern to follow: ManualRunClock (Mutex state, id per wait, a cancelled set, waitForSleepers).
  timestamp: 2026-10-14T17:07:10.017386+00:00
- actor: claude-code
  id: 01m4xpg28wpz15xhahw697bzgy
  text: |-
    Implementation landed.

    Shape: `public func wait(until condition: @escaping @Sendable (Context) -> Bool) async`. The card shape had no @escaping. The capture must keep the condition until a record arrives, thus the closure must be escaping. A cancel ends the wait with no throw.

    Also new public API:
    - `public func waitForWaiters(atLeast count: Int) async` (same pattern as ManualRunClock.waitForSleepers). A test calls it to know that a wait started before the record.
    - `public var observedMetricsFactory: any MetricsFactory`. The capture now binds this factory with withMetricsFactory. It keeps each metric in metricsFactory (TestMetrics), and each made metric and each recorded value resumes the waits. A metric that code makes directly with context.metricsFactory does not resume a wait, because TestMetrics is a final class with no hook.

    Span hook: W3CInMemoryTracer gives the code a front InMemorySpan. Its onEnd copies the finished state to the InMemoryTracer span, ends that span at the same instant, then calls the hook. activeSpans and activeSpan(identifiedBy:) give the front spans.

    Dead end: one generic handler class with four conditional conformances (CounterHandler, MeterHandler, RecorderHandler, TimerHandler) did not compile, because each inherits _SwiftMetricsSendableProtocol. An unconditional conformance to _SwiftMetricsSendableProtocol on the class corrects it.

    Note: swift build --build-tests ran 4 times, because the first 3 runs had compile errors.
  timestamp: 2026-10-14T17:13:56.252429+00:00
- actor: claude-code
  id: 01m4xpg59n4k0r1mx0ab6s0b01
  text: |-
    ### implement — changed
    - evidence: 6 files — Tests/TelemetryTestSupport/TelemetryWaitList.swift (new), Tests/TelemetryTestSupport/ObservedMetricsFactory.swift (new), Tests/TelemetryTestSupport/TelemetryCapture.swift, Tests/TelemetryTestSupport/W3CInMemoryTracer.swift, Tests/TelemetryTestSupport/TelemetryLogRouting.swift, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryCaptureWaitTests.swift (new). `swift build --build-tests` green; `swift test --skip-build --filter TelemetryCaptureWaitTests` 6/6 passed; `swift test` 1138 tests in 106 suites passed, 0 failures.
    - next: /review. The push and the mail to the peer session stay open.
  timestamp: 2026-10-14T17:13:59.349873+00:00
position_column: doing
position_ordinal: '80'
title: 'TelemetryCapture.Context: add an event wait for spans, log records and metric records'
---
TelemetryTestSupport.TelemetryCapture.Context gives only reads of its spans, logRecords and metricsFactory. Thus, ACPAgent tests must poll it.

Add an event wait on Context: `func wait(until condition: @Sendable (Context) -> Bool) async`. If a different shape fits the type better, use that shape and tell the mail peer session which shape you used.

Rules:
- [x] Each finished span, each log record and each metric record resumes the waits whose condition is now true.
- [x] Do not use a clock, a poll, a sleep or a retry.
- [x] A cancel of the waiting task ends the wait.
- [x] Fixed-order test: a wait that starts before the record ends.
- [x] Fixed-order test: a wait that starts after the record ends at once.
- [x] Fixed-order test: a cancel ends a wait.
- [ ] Run the full suite one time. Push when it is green. Send the commit to the mail peer session.

The mail step 4 work found this gap. #mail-step-4