import InMemoryLogging
import InMemoryTracing
import Logging
import Metrics
import MetricsTestKit
import Testing
import Tracing

/// The content-safety helper of the telemetry of the family.
///
/// Rule 4 of the OpenTelemetry design of 2026-09-28: a span attribute, a log
/// message, a log metadata value and a metric dimension carry ids, names,
/// counts and sizes only. They never carry a prompt, a response, tool
/// arguments, tool output, embed text or an LSP payload, because each record
/// leaves the process through the telemetry backend of the host. Rule 5: each
/// package proves rule 4 with a content-safety test that uses this helper.
///
/// ``run(forbidding:sourceLocation:_:)`` gives the code under test
/// a new ``Context``, with an in-memory tracer, log handler and metrics
/// factory. The tracer is a ``W3CInMemoryTracer``: it injects and extracts
/// W3C `traceparent` and `tracestate` values, thus the "enter" record of
/// `TracedCall` holds the `trace.id` and the `span.id` of its span, and a test
/// can prove that a `traceparent` value goes across a process boundary.
/// After the code, it records one issue for each place that contains
/// a forbidden string. The code under test can use the telemetry of the
/// context in two ways:
///
/// - Explicitly: give ``Context/tracer``, ``Context/logger`` or
///   ``Context/metricsFactory`` to the code, for example
///   `ToolCallSpan.withSpan(tracer: context.tracer, ...)`.
/// - Globally: `InstrumentationSystem.tracer` gives the tracer of the context,
///   because the capture binds it with `withTracer`. A new `Counter`, `Timer`
///   or other metric uses the factory of the context, because the capture
///   binds it with `withMetricsFactory`. A new `Logger(label:)` writes to the
///   context, because the capture bootstraps the logging system with a
///   handler that sends each record to the capture of its task.
///
/// The capture calls `LoggingSystem.bootstrap` one time for each process, on
/// the first capture. It calls no `MetricsSystem.bootstrap` and no
/// `InstrumentationSystem.bootstrap`: swift-metrics and
/// swift-distributed-tracing read the task-local factory and the task-local
/// tracer first. Thus:
///
/// - A test process that uses this helper must not bootstrap the logging
///   system itself.
/// - A logger that the code made before the first capture keeps the handler
///   of that time, and a metric keeps the factory of the time that the code
///   made it. Make the logger and the metrics in the code under test, or give
///   the telemetry of the context to the code.
/// - Each capture has its own records. Tests that run in parallel do not see
///   the records of each other, because each record goes to the capture of
///   its task. A child task gets the capture of its parent task. A detached
///   task gets no capture.
///
/// ```swift
/// try await TelemetryCapture.run(forbidding: [argument, output]) { context in
///     _ = try await ToolCallSpan.withSpan(tracer: context.tracer, ...) { _ in output }
/// }
/// ```
public enum TelemetryCapture {
    /// The label of the logger of each context.
    public static let loggerLabel = "TelemetryCapture"

    /// Runs `body` in a new capture, then records an issue for each place that
    /// contains a forbidden string.
    ///
    /// The capture records the issues also when `body` throws, because an
    /// error path can leak content too.
    ///
    /// - Parameters:
    ///   - forbidden: The strings that no place may contain, for example the
    ///     prompt, the tool arguments and the tool output of the test. An
    ///     empty string matches each place.
    ///   - sourceLocation: The source location that each issue names.
    ///   - body: The code under test. It gets the context of the capture, and
    ///     it runs on the actor of the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    @discardableResult
    public nonisolated(nonsending) static func run<Result>(
        forbidding forbidden: [String],
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: nonisolated(nonsending) (Context) async throws -> Result
    ) async throws -> Result {
        TelemetryLogRouting.bootstrapOnce
        let context = Context()
        defer {
            for leak in context.leaks(forbidding: forbidden) {
                Issue.record("\(leak)", sourceLocation: sourceLocation)
            }
        }
        return try await withTracer(context.tracer) {
            try await withMetricsFactory(context.metricsFactory) {
                try await TelemetryLogRouting.currentContext.withValue(context) {
                    try await body(context)
                }
            }
        }
    }
}

extension TelemetryCapture {
    /// One log record that a capture keeps: the level, the message, the error
    /// and the merged metadata of the call, and the label of the logger that
    /// wrote it.
    ///
    /// Two records are equal when their labels are equal and swift-log's
    /// `InMemoryLogHandler.Entry` finds the other four values equal. That
    /// comparison finds two errors equal when their types and their
    /// descriptions are equal.
    public struct LogRecord: Equatable, Sendable {
        /// The level of the record.
        public let level: Logger.Level

        /// The message of the record.
        public let message: Logger.Message

        /// The error of the record, or `nil` when the call gave no error.
        public let error: (any Error)?

        /// The merged metadata of the record: the metadata of the logger, then
        /// the provided metadata, then the metadata of the call.
        public let metadata: Logger.Metadata

        /// The label of the logger that wrote the record.
        public let label: String

        /// Makes a log record.
        ///
        /// - Parameters:
        ///   - level: The level of the record.
        ///   - message: The message of the record.
        ///   - error: The error of the record, or `nil` for no error.
        ///   - metadata: The merged metadata of the record.
        ///   - label: The label of the logger that wrote the record.
        public init(
            level: Logger.Level,
            message: Logger.Message,
            error: (any Error)? = nil,
            metadata: Logger.Metadata,
            label: String
        ) {
            self.level = level
            self.message = message
            self.error = error
            self.metadata = metadata
            self.label = label
        }

        /// Compares the labels, then the other values as swift-log's
        /// `InMemoryLogHandler.Entry` compares them.
        ///
        /// - Parameters:
        ///   - lhs: A record.
        ///   - rhs: A different record.
        /// - Returns: `true` when the two records are equal.
        public static func == (lhs: LogRecord, rhs: LogRecord) -> Bool {
            lhs.label == rhs.label && lhs.entry == rhs.entry
        }

        /// The record without its label, as swift-log keeps it.
        private var entry: InMemoryLogHandler.Entry {
            InMemoryLogHandler.Entry(level: level, message: message, error: error, metadata: metadata)
        }
    }

    /// The telemetry objects of one capture, and the records that they hold.
    public struct Context: Sendable {
        /// The tracer of the capture. It keeps each span that ends, and it
        /// injects and extracts the span context as W3C `traceparent` and
        /// `tracestate` values. Its ``W3CInMemoryTracer/inMemoryTracer`` is
        /// the `InMemoryTracer` that keeps the spans.
        public let tracer: W3CInMemoryTracer

        /// The metrics factory of the capture. It keeps each metric that the
        /// code makes.
        public let metricsFactory: TestMetrics

        /// A logger that writes each level to the capture.
        public let logger: Logger

        /// The store that keeps the log records of the capture.
        let logRecordStore: LogRecordStore

        /// Makes the telemetry objects of a new capture.
        init() {
            let store = LogRecordStore()
            logRecordStore = store
            tracer = W3CInMemoryTracer()
            metricsFactory = TestMetrics()
            logger = Logger(label: TelemetryCapture.loggerLabel) { label in
                RoutingLogHandler(label: label, destination: .store(store))
            }
        }

        /// The spans that ended in the capture, in the order of their end.
        public var spans: [FinishedInMemorySpan] {
            tracer.finishedSpans
        }

        /// The log records of the capture, in the order of the calls. Each
        /// record has the label of the logger that wrote it.
        public var logRecords: [LogRecord] {
            logRecordStore.records
        }

        /// The metrics that the code made in the capture, in the order of
        /// their labels.
        public var metricRecords: [MetricRecord] {
            let counters = metricsFactory.counters.map { MetricRecord(kind: .counter, label: $0.label, dimensions: $0.dimensions) }
            let meters = metricsFactory.meters.map { MetricRecord(kind: .meter, label: $0.label, dimensions: $0.dimensions) }
            let recorders = metricsFactory.recorders.map { MetricRecord(kind: .recorder, label: $0.label, dimensions: $0.dimensions) }
            let timers = metricsFactory.timers.map { MetricRecord(kind: .timer, label: $0.label, dimensions: $0.dimensions) }
            return (counters + meters + recorders + timers).sorted { ($0.label, $0.kind.rawValue) < ($1.label, $1.kind.rawValue) }
        }

        /// Each place of the records: the spans, then the log records, then
        /// the metrics.
        public var places: [TelemetryPlace] {
            spanPlaces + logPlaces + metricRecords.flatMap(\.places)
        }

        /// The places that contain a forbidden string.
        ///
        /// - Parameter forbidden: The strings that no place may contain. An
        ///   empty string matches each place.
        /// - Returns: One leak for each place and each forbidden string that
        ///   the place contains, in the order of ``places``.
        public func leaks(forbidding forbidden: [String]) -> [TelemetryLeak] {
            places.flatMap { place in
                forbidden
                    .filter { place.description.contains($0) }
                    .map { TelemetryLeak(place: place, forbidden: $0) }
            }
        }

        /// The places of the spans: the name of each span, then each of its
        /// attributes, in the order of the keys.
        private var spanPlaces: [TelemetryPlace] {
            spans.flatMap { span in
                [.spanName(span.operationName)] + Self.attributePlaces(of: span)
            }
        }

        /// The places of the attributes of one span, in the order of the keys.
        ///
        /// - Parameter span: The span.
        /// - Returns: One place for each attribute.
        private static func attributePlaces(of span: FinishedInMemorySpan) -> [TelemetryPlace] {
            // `SpanAttributes` is not a `Sequence`: `forEach` is its only walk
            // of the attributes, thus the walk collects them into an array. A
            // `for` loop over `SpanAttributes` does not compile.
            var attributes: [(key: String, value: SpanAttribute)] = []
            // swiftformat:disable:next preferForLoop  SpanAttributes is not a Sequence, thus no for loop compiles
            span.attributes.forEach { key, value in
                attributes.append((key, value))
            }
            return attributes
                .sorted { $0.key < $1.key }
                .map { .spanAttribute(span: span.operationName, key: $0.key, value: text(of: $0.value)) }
        }

        /// The text of a span attribute value, as a telemetry backend shows it.
        ///
        /// - Parameter value: The attribute value.
        /// - Returns: The string of a string value, or else the description
        ///   of the value, which holds each of its elements.
        private static func text(of value: SpanAttribute) -> String {
            if case .string(let text) = value {
                return text
            }
            return String(describing: value)
        }

        /// The places of the log records: the message of each record, then
        /// each of its metadata values, in the order of the keys.
        private var logPlaces: [TelemetryPlace] {
            logRecords.flatMap { record in
                [.logMessage(level: record.level, message: "\(record.message)")]
                    + record.metadata.sorted { $0.key < $1.key }.map { .logMetadata(key: $0.key, value: "\($0.value)") }
            }
        }
    }
}
