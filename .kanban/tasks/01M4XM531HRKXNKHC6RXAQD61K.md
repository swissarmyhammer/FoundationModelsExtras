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
- actor: claude-code
  id: 01m4xpszaehm7bn11v7cxx9v5s
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 3d02961). 3 findings confirmed, 8 refuted. Tests/TelemetryTestSupport/ObservedMetricsFactory.swift:80, Tests/TelemetryTestSupport/ObservedMetricsFactory.swift:94, Tests/TelemetryTestSupport/ObservedMetricsFactory.swift:175
    - next: Do the 3 open items in the "Review Findings (2026-10-14 12:14)" section. The push-and-send item is not a review finding. Do it after the review is clean.
  timestamp: 2026-10-14T17:19:20.910677+00:00
- actor: claude-code
  id: 01m4xptbj6yy34pbvs7td2v917
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files in Tests/TelemetryTestSupport and the new wait tests
    - test: green — the full swift test suite ran one time in the implement step, 1138 passed
    - commit: 3d02961
    - review: findings — ObservedMetricsFactory.swift:80, ObservedMetricsFactory.swift:94, ObservedMetricsFactory.swift:175
  timestamp: 2026-10-14T17:19:33.446628+00:00
- actor: claude-code
  id: 01m4xqwkw6pzwf9tb00vsdppc1
  text: |-
    Discovery: the destroy* methods of ObservedMetricsFactory did not remove any metric before this fix. `Self.target(of: handler)` is generic over `Handler`, and Swift opens the existential argument. Thus `Handler` was `ObservedMetricHandler<any CounterHandler>`, the cast to `ObservedMetricHandler<Handler>` failed, and TestMetrics got the front handler, which it ignores. A standalone swiftc check confirmed it: the generic cast gives false, and the cast with `handler as any CounterHandler` gives true. The fix gives each call the existential (`handler as any XHandler`).

    Dead end: the first filtered run of TelemetryCaptureWaitTests hung for 15 minutes (the 900 s timeout killed the shell call), because the new destroy test waited for a removal that never occurred. A `sample` of the test process showed all threads idle, which is a continuation that never resumed.
  timestamp: 2026-10-14T17:38:16.070645+00:00
- actor: claude-code
  id: 01m4xqz4b6f84nv6x6bmq6pdjw
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/TelemetryTestSupport/ObservedMetricsFactory.swift (each of the 4 destroy methods calls metricDidChange through a new private `removed` helper; each gives the handler as an existential so that the cast to the TestMetrics handler succeeds), Tests/TelemetryTestSupport/TelemetryCapture.swift (the docs say that a removal ends waits), Tests/FoundationModelsExtrasTests/Telemetry/TelemetryCaptureWaitTests.swift (2 new tests: a meter write through observedMetricsFactory, and a counter destroy during a wait). `swift build --build-tests` 1 run (its output went through a pipe by mistake, thus it gave no result; the filtered test run built the code). `swift test --filter TelemetryCaptureWaitTests` 2 runs: the first hung on the destroy bug and the timeout killed it; the second passed 8/8. `swift test` 1 run: 1140 tests in 106 suites passed, 0 failures. The only warning is the SwiftPM build-system warning "missing creator for mutated node" for the mlx-swift_Cmlx.bundle, which was present before this change.
    - next: /review. The push and the mail to the peer session stay open.
  timestamp: 2026-10-14T17:39:38.470928+00:00
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

## Review Findings (2026-10-14 12:14)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/TelemetryTestSupport/ObservedMetricsFactory.swift:80` `completeness/inverse-operation-coverage` — `makeCounter` tells the capture about each new metric through `observed`, which calls `metricDidChange`. Its inverse, `destroyCounter`, removes the metric from `TestMetrics` without telling the capture. A wait whose condition reads `metricRecords` cannot see the removal, so the make and destroy directions are not symmetric. Call `metricDidChange()` after `metrics.destroyCounter(...)`, or record in the doc that destroy does not end waits. Add one test that destroys a counter during a wait and asserts the wait's behaviour.
- [x] `Tests/TelemetryTestSupport/ObservedMetricsFactory.swift:94` `completeness/inverse-operation-coverage` — `destroyRecorder` removes a metric without notifying the capture, while `makeRecorder` notifies. The make/destroy asymmetry applies to recorders as well. Notify the capture after `destroyRecorder`, or document why destroy does not end waits.
- [x] `Tests/TelemetryTestSupport/ObservedMetricsFactory.swift:175` `completeness/invariant-propagation` — The MeterHandler conformance routes each value through `apply`, which calls `metricDidChange`, so meter writes end waits. No test in the diff writes to a meter through the observed factory. The wait doc says every metric the factory makes ends waits, but only the counter path is exercised, so the meter path is unproven. Add one wait test that writes a meter (for example `Metrics.Meter(label:).set(...)`) through `observedMetricsFactory` and asserts the wait ends. The test should read the value back through `metricsFactory`.
