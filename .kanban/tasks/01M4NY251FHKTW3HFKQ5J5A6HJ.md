---
assignees:
- claude-code
depends_on:
- 01M4NYFFAQH23KD4E03AC35EK3
position_column: todo
position_ordinal: 8c80
title: 'Marketplace telemetry: add the API dependencies, a vocabulary file, and spans and timers for passes, head checks and fetches'
---
## What

The `Marketplace` target has no telemetry. A slow or hung git fetch, or a pass that fails again and again, shows nothing. The target does not link swift-log, swift-metrics or swift-distributed-tracing: its dependencies (`Package.swift:303-312`) are `FoundationModelsExtras`, `Yams` and `libgit2` only.

Out of scope: `EventBroadcaster` (`Sources/Marketplace/EventBroadcaster.swift`) gets no queue metrics. It is a fan-out of events to subscribers, with no work task to time, and `AsyncStream` does not show its buffer count.

Approach:
- `Package.swift`: add `.product(name: "Logging", package: "swift-log")`, `.product(name: "Metrics", package: "swift-metrics")` and `.product(name: "Tracing", package: "swift-distributed-tracing")` to the `Marketplace` target, as API only. No backend, no `LoggingSystem.bootstrap`, no `MetricsSystem.bootstrap`. Add `TelemetryTestSupport` and `MetricsTestKit` to the `MarketplaceTests` test target (`:366`) for the tests.
- `Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift` must still pass. Extend it so that it also checks the `Marketplace` target: API products only, no backend, no bootstrap.
- New vocabulary file `Sources/Marketplace/MarketplaceTelemetry.swift`. Each span name, attribute key, metric name and log metadata key of the target goes there, and each name starts with `Marketplace.`. No other file of the target has a telemetry string literal. Make the metric objects at call time.
- `Sources/Marketplace/MarketplaceStore.swift`: a span for each of `runPass(_:atIndex:)` (`:742`), `checkHead(remote:current:atIndex:)` (`:849`), `sync(remote:atIndex:force:)` (`:918`), `fetch(remote:revision:)` (`:1069`), `remoteHead(of:)` (`:1107`) and `materialize(remote:source:commit:)` (`:1131`). Attributes: `marketplace.id` (the display id), `pass.kind` and the outcome. Use `TracedCall` for `fetch` and `remoteHead`, so that a hung network call has an "enter" record.
- Timers of the fetch and of the head check. A Counter of passes by result: `up_to_date`, `updated` or `failed`. Take the result from the safe `MarketplaceEvent` cases (`checked`, `updateAvailable`, `updated`, `failed`; `Sources/Marketplace/MarketplaceEvent.swift:9-50`). Do not record the `error: String` of `MarketplaceEvent.failed` (`:49`) in a span, a log record or a metric; record `error.type` only.
- Never record a URL, a credential, a ref that a user typed, or a path.

## Acceptance Criteria
- [ ] The `Marketplace` target links the logging, metrics and tracing API products, and `TelemetryDependencyTests` checks that it links no backend and calls no bootstrap.
- [ ] `MarketplaceTelemetry.swift` holds each telemetry name of the target, and each name starts with `Marketplace.`.
- [ ] Each pass opens a span with `marketplace.id`, `pass.kind` and the outcome, with child spans for the head check, the sync, the fetch, the remote head and the materialize step when they run.
- [ ] Each fetch and each head check records one duration, and each pass adds one count with its result (`up_to_date`, `updated` or `failed`).
- [ ] No span, log record or metric carries the `error: String` of `MarketplaceEvent.failed`.

## Tests
- [ ] `Tests/MarketplaceTests/MarketplaceStoreTests.swift` (target `MarketplaceTests`): with `GitFixtureRepository` and `RecordingGitTransport` from `MarketplaceFixtures`, `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test the span tree, the timers and the pass counter for a pass that is up to date, a pass that updates, and a pass that fails.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the remote URL, a credential, the cache path and the `error` text of a failed pass.
- [ ] `Tests/FoundationModelsExtrasTests/Telemetry/TelemetryDependencyTests.swift` covers the `Marketplace` target.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature