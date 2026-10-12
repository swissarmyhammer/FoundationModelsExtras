import InMemoryTracing
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import Marketplace

/// Reads and checks the telemetry that a store test or a cache test recorded:
/// the pass span and its child spans, the pass counter, the timers of the
/// fetch, of the remote head and of the install, and the counters of the
/// cache.
///
/// Each telemetry test of the store and of the cache uses these helpers, thus
/// a change to the names or the dimensions occurs in one place.
enum MarketplaceTelemetryExpectations {
  /// The attribute key that `TracedCall` gives a span whose body threw. The
  /// core target owns the key, thus the test names it here.
  static let errorTypeKey = "error.type"

  /// The prefix of each span name and each metric name of the target.
  static let namePrefix = "Marketplace."

  /// The count of spans of one name, of passes, or of durations that one
  /// pass over one marketplace gives.
  static let one = 1

  /// Runs `body` in a new telemetry capture, and expects that the capture saw
  /// at least one record. A capture that saw nothing proves nothing about
  /// the content of the records.
  ///
  /// - Parameters:
  ///   - forbidden: The strings that no span, log record or metric may hold.
  ///     The default is no string.
  ///   - body: The store work or the cache work under test.
  /// - Returns: The capture and the value of `body`.
  /// - Throws: The error of the capture.
  static func capture<Output>(
    forbidding forbidden: [String] = [],
    _ body: () async -> Output
  ) async throws -> (context: TelemetryCapture.Context, output: Output) {
    let captured = try await TelemetryCapture.run(forbidding: forbidden) { context in
      (context, await body())
    }
    #expect(!captured.0.places.isEmpty)
    return captured
  }

  /// Gives the one span of `spans` with the name `spanName`.
  ///
  /// - Parameters:
  ///   - spanName: The name of the span.
  ///   - spans: The spans that the capture recorded.
  /// - Returns: The span.
  /// - Throws: A failed requirement when `spans` holds no span or more than
  ///   one span with that name.
  static func onlySpan(named spanName: String, in spans: [FinishedInMemorySpan]) throws -> FinishedInMemorySpan {
    let named = spans.filter { $0.operationName == spanName }
    try #require(named.count == one)
    return try #require(named.first)
  }

  /// Gives the one child span of `parent` with the name `spanName`.
  ///
  /// - Parameters:
  ///   - spanName: The name of the child span.
  ///   - parent: The parent span.
  ///   - spans: The spans that the capture recorded.
  /// - Returns: The child span.
  /// - Throws: A failed requirement when `parent` has no child or more than
  ///   one child with that name.
  static func onlyChild(
    named spanName: String, of parent: FinishedInMemorySpan, in spans: [FinishedInMemorySpan]
  ) throws -> FinishedInMemorySpan {
    try onlySpan(named: spanName, in: spans.filter { $0.parentSpanID == parent.spanID })
  }

  /// Expects that `spans` holds no span with the name `spanName`.
  ///
  /// - Parameters:
  ///   - spanName: The name of the span that must not run.
  ///   - spans: The spans that the capture recorded.
  static func expectNoSpan(named spanName: String, in spans: [FinishedInMemorySpan]) {
    #expect(spans.filter { $0.operationName == spanName }.isEmpty)
  }

  /// Expects that `span` carries the display id, the kind and the outcome of
  /// one pass, and the error status when the pass failed.
  ///
  /// - Parameters:
  ///   - span: A pass span.
  ///   - id: The display id of the marketplace.
  ///   - kind: What the pass did.
  ///   - outcome: How the pass ended.
  static func expectPass(
    _ span: FinishedInMemorySpan, id: String, kind: MarketplacePassKind, outcome: MarketplacePassOutcome
  ) {
    expectMarketplaceID(of: span, id: id)
    #expect(span.attributes.get(MarketplaceTelemetry.AttributeKey.passKind) == .string(kind.rawValue))
    #expect(span.attributes.get(MarketplaceTelemetry.AttributeKey.passOutcome) == .string(outcome.rawValue))
    #expect((span.status?.code == .error) == (outcome == .failed))
  }

  /// Expects that `span` carries the display id of its marketplace.
  ///
  /// - Parameters:
  ///   - span: A span of the target.
  ///   - id: The display id of the marketplace.
  static func expectMarketplaceID(of span: FinishedInMemorySpan, id: String) {
    #expect(span.attributes.get(MarketplaceTelemetry.AttributeKey.marketplaceID) == .string(id))
  }

  /// Expects that `span` has the error status and an `error.type`.
  ///
  /// - Parameter span: A span whose body threw.
  static func expectFailure(of span: FinishedInMemorySpan) {
    #expect(span.status?.code == .error)
    #expect(span.attributes.get(errorTypeKey) != nil)
  }

  /// Gives the values of the pass counter of one marketplace, kind and
  /// outcome.
  ///
  /// - Parameters:
  ///   - metrics: The factory of the capture.
  ///   - id: The display id of the marketplace.
  ///   - kind: What the passes did.
  ///   - outcome: How the passes ended.
  /// - Returns: The count that each pass added, in order.
  /// - Throws: When `metrics` has no such counter.
  static func passCounts(
    in metrics: TestMetrics, id: String, kind: MarketplacePassKind, outcome: MarketplacePassOutcome
  ) throws -> [Int64] {
    try metrics.expectCounter(
      MarketplaceTelemetry.MetricName.passes,
      [
        (MarketplaceTelemetry.DimensionKey.marketplaceID, id),
        (MarketplaceTelemetry.DimensionKey.passKind, kind.rawValue),
        (MarketplaceTelemetry.DimensionKey.passOutcome, outcome.rawValue),
      ]
    ).values
  }

  /// Gives the values of one git timer of one marketplace and outcome.
  ///
  /// - Parameters:
  ///   - label: The label of the timer: the fetch timer or the remote head
  ///     timer.
  ///   - metrics: The factory of the capture.
  ///   - id: The display id of the marketplace.
  ///   - outcome: How the git calls ended.
  /// - Returns: The duration of each call in nanoseconds, in order.
  /// - Throws: When `metrics` has no such timer.
  static func durations(
    of label: String, in metrics: TestMetrics, id: String, outcome: MarketplaceCallOutcome
  ) throws -> [Int64] {
    try durations(
      of: label, in: metrics, id: id, outcomeKey: MarketplaceTelemetry.DimensionKey.gitOutcome, outcome: outcome)
  }

  /// Gives the values of the install timer of one marketplace and outcome.
  ///
  /// - Parameters:
  ///   - metrics: The factory of the capture.
  ///   - id: The display id of the marketplace.
  ///   - outcome: How the installs ended.
  /// - Returns: The duration of each install in nanoseconds, in order.
  /// - Throws: When `metrics` has no such timer.
  static func installDurations(
    in metrics: TestMetrics, id: String, outcome: MarketplaceCallOutcome
  ) throws -> [Int64] {
    try durations(
      of: MarketplaceTelemetry.MetricName.installDuration, in: metrics, id: id,
      outcomeKey: MarketplaceTelemetry.DimensionKey.installOutcome, outcome: outcome)
  }

  /// Expects that `metrics` holds no install timer with the outcome
  /// `outcome`.
  ///
  /// - Parameters:
  ///   - outcome: The outcome that no install must record.
  ///   - metrics: The factory of the capture.
  static func expectNoInstallDuration(_ outcome: MarketplaceCallOutcome, in metrics: TestMetrics) {
    let outcomeKey = MarketplaceTelemetry.DimensionKey.installOutcome
    #expect(
      metrics.timers.filter { timer in
        timer.label == MarketplaceTelemetry.MetricName.installDuration
          && timer.dimensions.contains { $0.0 == outcomeKey && $0.1 == outcome.rawValue }
      }.isEmpty)
  }

  /// Gives the values of one counter of the cache of one marketplace: the
  /// writer-lock conflict counter or the removed-snapshot counter.
  ///
  /// - Parameters:
  ///   - label: The label of the counter.
  ///   - metrics: The factory of the capture.
  ///   - id: The display id of the marketplace.
  /// - Returns: The count that each event added, in order.
  /// - Throws: When `metrics` has no such counter.
  static func cacheCounts(of label: String, in metrics: TestMetrics, id: String) throws -> [Int64] {
    try metrics.expectCounter(label, [(MarketplaceTelemetry.DimensionKey.marketplaceID, id)]).values
  }

  /// Expects that `metrics` holds no counter with the label `label`.
  ///
  /// - Parameters:
  ///   - label: The label of the counter that must not count.
  ///   - metrics: The factory of the capture.
  static func expectNoCounter(_ label: String, in metrics: TestMetrics) {
    #expect(metrics.counters.filter { $0.label == label }.isEmpty)
  }

  /// Gives the values of one timer of one marketplace and outcome.
  ///
  /// - Parameters:
  ///   - label: The label of the timer.
  ///   - metrics: The factory of the capture.
  ///   - id: The display id of the marketplace.
  ///   - outcomeKey: The dimension key of the outcome of the timer.
  ///   - outcome: How the timed calls ended.
  /// - Returns: The duration of each call in nanoseconds, in order.
  /// - Throws: When `metrics` has no such timer.
  private static func durations(
    of label: String, in metrics: TestMetrics, id: String, outcomeKey: String, outcome: MarketplaceCallOutcome
  ) throws -> [Int64] {
    try metrics.expectTimer(
      label,
      [
        (MarketplaceTelemetry.DimensionKey.marketplaceID, id),
        (outcomeKey, outcome.rawValue),
      ]
    ).values
  }

  /// Expects that `values` holds one duration, and that it is not negative.
  ///
  /// - Parameter values: The values of a timer, in nanoseconds.
  static func expectOneDuration(_ values: [Int64]) {
    #expect(values.count == one)
    #expect(values.allSatisfy { $0 >= 0 })
  }

  /// Expects that each span name and each metric name of a capture starts
  /// with ``namePrefix``.
  ///
  /// - Parameter context: The capture.
  static func expectEachNameHasThePrefix(in context: TelemetryCapture.Context) {
    #expect(!context.spans.isEmpty)
    #expect(context.spans.map(\.operationName).filter { !$0.hasPrefix(namePrefix) } == [])
    #expect(context.metricRecords.map(\.label).filter { !$0.hasPrefix(namePrefix) } == [])
  }
}
