---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mq1g9mpvew1vddq1dgcvej
  text: |-
    Research:
    - The pinned releases have the in-memory backends: swift-log 1.15.1 has the `InMemoryLogging` product (`InMemoryLogHandler`, it merges handler metadata, provider metadata and call metadata). swift-metrics 2.11.0 has the `MetricsTestKit` product (`TestMetrics`). swift-distributed-tracing 1.5.0 has `InMemoryTracing`.
    - swift-distributed-tracing 1.5.0 has `withTracer(_:_:)`, and `InstrumentationSystem.tracer` reads that task-local tracer first. swift-metrics 2.11.0 has `withMetricsFactory(_:_:)`, and `Counter(label:)` and the other metrics read `MetricsSystem.factory`, which reads that task-local factory first. Thus spans and metrics need no global bootstrap: the helper binds the tracer and the factory of each capture as task-local values.
    - swift-log 1.15.1 has no task-local logger. Thus the helper calls `LoggingSystem.bootstrap` one time for each process, with a routing `LogHandler` that sends each record to the capture in a `TaskLocal` value. A record outside a capture goes nowhere.
    - `ToolCallSpan.withSpan(tracer:)` uses `tracer ?? InstrumentationSystem.tracer`, thus both the explicit tracer and the task-local tracer work.
    - No test of this package bootstraps a backend now. `TelemetryDependencyTests` forbids a bootstrap only under `Sources/`; the new target is under `Tests/`.
  timestamp: 2026-09-28T19:14:35.956465+00:00
- actor: claude-code
  id: 01m3mqpj05x6p57gsrrf68ks99
  text: |-
    ### implement — changed
    - evidence: 7 files — Package.swift, CHANGELOG.md, Tests/TelemetryTestSupport/TelemetryCapture.swift, Tests/TelemetryTestSupport/TelemetryLogRouting.swift, Tests/TelemetryTestSupport/TelemetryPlace.swift, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryCaptureTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift. `swift test --filter 'FoundationModelsExtrasTests\.(TelemetryCaptureTests|ToolCallSpanTests)'`: 10 tests in 2 suites passed, with the 4 expected known issues.
    - notes: `run` is `nonisolated(nonsending)`, because the `TaskLocal.withValue(_:operation:isolation:)` overload is deprecated in this toolchain. The test target has an internal `Counter` class (ModelPoolTestSupport.swift), thus the tests write `Metrics.Counter`. Each place list also holds `span <name>` and `metric <name>`, thus a forbidden string in a span name or a metric name is a leak too.
    - next: /test
  timestamp: 2026-09-28T19:26:05.829941+00:00
- actor: claude-code
  id: 01m3mqthefkbnvf1n0fkdfvb0g
  text: |-
    ### test — green
    - evidence: `swift test --parallel` exit 0 — 1393 tests passed (756 in 75 suites of FoundationModelsExtrasTests with the 4 expected known issues, plus 396, 131, 44, 40 and 26 in the other targets), 0 failed, 0 skipped. No compiler warning. The only `warning:` lines are 26 SwiftPM manifest-cache "disk I/O error" lines of the environment, not of the code.
    - next: /commit
  timestamp: 2026-09-28T19:28:16.335272+00:00
depends_on:
- 01M3MN838VZ4QX57C3965XMGKV
position_column: doing
position_ordinal: '80'
title: 'OTel B: add a TelemetryTestSupport product with a content-safety helper for spans, logs and metrics'
---
## What

Part B of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 4: no prompt, response, tool arguments, tool output, embed text or LSP payloads in span attributes, log messages, log metadata or metric dimensions. Only ids, names, counts and sizes. Rule 5: each package has a content-safety test that uses one shared helper from FoundationModelsExtras. Router, Multitool, the metadata registry and the ACP packages will use this product.

Source to generalize: `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SpanContentSafetyTests.swift`. It uses an `InMemoryTracer`, renders each attribute of each finished span as `<span>.<key> = <value>`, and fails on a value that contains a fixture string. It checks spans only.

Make a new library target and product `TelemetryTestSupport` at `Tests/TelemetryTestSupport/` in `/Users/wballard/github/swissarmyhammer/FoundationModelsExtras/Package.swift`. Use the same idiom as `MarketplaceFixtures` (a plain library target and a product, so that test targets of other packages can import it).

- [x] Dependencies: `Tracing` and `InMemoryTracing` (swift-distributed-tracing), `Logging` (swift-log), `Metrics` and the test kit of swift-metrics (`MetricsTestKit`, if that product exists in the pinned release; if not, write an in-memory `MetricsFactory`).
- [x] An in-memory `LogHandler` that records each message, its level and its metadata (merged handler metadata plus call metadata). Use one from swift-log if the pinned release has one; if not, write it.
- [x] Global bootstrap happens only one time for each process (`LoggingSystem.bootstrap`, `MetricsSystem.bootstrap`, `InstrumentationSystem.bootstrap`). Parallel tests must not see the records of other tests. Recommended approach: the helper bootstraps each system one time with a routing backend that sends each record to a sink in a `@TaskLocal` value, and the helper binds a new sink for each call. Also let a caller give an explicit tracer, logger and metrics factory to the code under test (for example `ToolCallSpan.withSpan(tracer:)` already takes a tracer).
- [x] The public API, for example: `TelemetryCapture.run(forbidding: [String], _ body: (TelemetryCapture.Context) async throws -> T) async throws -> T`, where `Context` gives the `tracer`, a `logger` and the recorded spans, log records and metric records. After `body`, it reports an Issue (swift-testing `Issue.record`) for each span attribute, log message, log metadata value, or metric label/dimension that contains one of the forbidden strings. Each issue names the place, as `<span>.<key> = <value>`, `log <level>: <message>`, `log metadata <key> = <value>`, or `metric <name> <label> = <value>`.
- [x] Document the rule and the API with doc comments in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] Another package can add `.product(name: "TelemetryTestSupport", package: "FoundationModelsExtras")` to a test target and call the helper.
- [x] The helper reports an issue for a forbidden string in each of the four places: span attribute, log message, log metadata, metric dimension.
- [x] The helper reports no issue when the forbidden string is absent.
- [x] Two tests that run in parallel do not see the records of each other.

## Tests
- [x] New `Tests/FoundationModelsExtrasTests/Telemetry/TelemetryCaptureTests.swift` (add `TelemetryTestSupport` to the dependencies of `FoundationModelsExtrasTests`): one test for each of the four places that puts a fixture string there and checks that the helper records the issue (use `withKnownIssue` or an inspectable result API), one clean test, and one test that runs two captures concurrently and checks that each sees only its own records.
- [x] Change `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift` or add one test so that the tool span passes the helper with a tool argument and output as the forbidden strings.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.