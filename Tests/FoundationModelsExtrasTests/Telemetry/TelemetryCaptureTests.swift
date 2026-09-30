import Logging
import Metrics
import TelemetryTestSupport
import Testing
import Tracing

/// ``TelemetryCapture`` records an issue for a forbidden string in each place:
/// a span attribute, a span link attribute, a span event name, a span event
/// attribute, the description of an error that a span records, an attribute of
/// that error, the status message of a span, a log message, the error of a log
/// record, a log metadata value and a metric dimension. It records no issue
/// for clean telemetry, and each capture sees only the records of its own task.
@Suite("TelemetryCapture: a forbidden string in a span, a log record or a metric is an issue")
struct TelemetryCaptureTests {
    /// The content that no place may carry.
    private static let forbidden = "caller-content-5e1a"

    /// The name of the span that each test opens.
    private static let spanName = "probe.span"

    /// The name of the span event that each test adds.
    private static let eventName = "probe.event"

    /// The attribute key, the metadata key and the dimension key of each test.
    private static let key = "probe.key"

    /// The label of the logger that each test makes.
    private static let loggerLabel = "probe.logger"

    /// The label of a second logger, which differs from ``loggerLabel``.
    private static let otherLoggerLabel = "probe.other-logger"

    /// The label of the counter that each test makes.
    private static let metricLabel = "probe.calls"

    /// A value that is safe: an id, not content.
    private static let safeValue = "probe-id-17"

    /// The log message of the clean records.
    private static let safeMessage = "probe call ended"

    @Test("a forbidden string in a span attribute is an issue that names the span and the key")
    func aForbiddenSpanAttributeIsAnIssue() async throws {
        let place = TelemetryPlace.spanAttribute(span: Self.spanName, key: Self.key, value: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            InstrumentationSystem.tracer.withSpan(Self.spanName) { span in
                span.attributes[Self.key] = Self.forbidden
            }
        }

        #expect(context.spans.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in a span link attribute is an issue that names the span and the key")
    func aForbiddenSpanLinkAttributeIsAnIssue() async throws {
        let place = TelemetryPlace.spanLinkAttribute(span: Self.spanName, key: Self.key, value: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            InstrumentationSystem.tracer.withSpan(Self.spanName) { span in
                span.addLink(SpanLink(context: .topLevel, attributes: [Self.key: .string(Self.forbidden)]))
            }
        }

        #expect(context.spans.first?.links.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in a span event name is an issue that names the span")
    func aForbiddenSpanEventNameIsAnIssue() async throws {
        let place = TelemetryPlace.spanEventName(span: Self.spanName, event: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            InstrumentationSystem.tracer.withSpan(Self.spanName) { span in
                span.addEvent(SpanEvent(name: Self.forbidden))
            }
        }

        #expect(context.spans.first?.events.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in a span event attribute is an issue that names the span, the event and the key")
    func aForbiddenSpanEventAttributeIsAnIssue() async throws {
        let place = TelemetryPlace.spanEventAttribute(span: Self.spanName, event: Self.eventName, key: Self.key, value: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            InstrumentationSystem.tracer.withSpan(Self.spanName) { span in
                span.addEvent(SpanEvent(name: Self.eventName, attributes: [Self.key: .string(Self.forbidden)]))
            }
        }

        #expect(context.spans.first?.events.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in the description of an error that a span records is an issue that names the span")
    func aForbiddenRecordedErrorDescriptionIsAnIssue() async throws {
        let place = TelemetryPlace.spanError(span: Self.spanName, description: Self.forbidden)
        let error = ProbeError(description: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            #expect(throws: error) {
                try InstrumentationSystem.tracer.withSpan(Self.spanName) { _ in
                    throw error
                }
            }
        }

        #expect(context.spans.first?.errors.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in an attribute of a recorded error is an issue that names the span and the key")
    func aForbiddenRecordedErrorAttributeIsAnIssue() async throws {
        let place = TelemetryPlace.spanErrorAttribute(span: Self.spanName, key: Self.key, value: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            InstrumentationSystem.tracer.withSpan(Self.spanName) { span in
                span.recordError(ProbeError(description: Self.safeValue), attributes: [Self.key: .string(Self.forbidden)])
            }
        }

        #expect(context.spans.first?.errors.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in the status message of a span is an issue that names the span")
    func aForbiddenSpanStatusMessageIsAnIssue() async throws {
        let place = TelemetryPlace.spanStatusMessage(span: Self.spanName, message: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            InstrumentationSystem.tracer.withSpan(Self.spanName) { span in
                span.setStatus(SpanStatus(code: .error, message: Self.forbidden))
            }
        }

        #expect(context.spans.first?.status?.message == Self.forbidden)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in a log message is an issue that names the level and the message")
    func aForbiddenLogMessageIsAnIssue() async throws {
        let place = TelemetryPlace.logMessage(level: .info, message: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            Logger(label: Self.loggerLabel).info("\(Self.forbidden)")
        }

        #expect(context.logRecords.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in the description of the error of a log record is an issue that names the level")
    func aForbiddenLogErrorIsAnIssue() async throws {
        let place = TelemetryPlace.logError(level: .error, description: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            Logger(label: Self.loggerLabel).error("\(Self.safeMessage)", error: ProbeError(description: Self.forbidden))
        }

        #expect(context.logRecords.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in a log metadata value is an issue that names the key")
    func aForbiddenLogMetadataValueIsAnIssue() async throws {
        let place = TelemetryPlace.logMetadata(key: Self.key, value: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { context in
            context.logger.info("\(Self.safeMessage)", metadata: [Self.key: "\(Self.forbidden)"])
        }

        #expect(context.logRecords.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("a forbidden string in a metric dimension is an issue that names the metric and the dimension")
    func aForbiddenMetricDimensionIsAnIssue() async throws {
        let place = TelemetryPlace.metricDimension(metric: Self.metricLabel, key: Self.key, value: Self.forbidden)

        let context = try await Self.captureWithKnownIssue(at: place) { _ in
            Metrics.Counter(label: Self.metricLabel, dimensions: [(Self.key, Self.forbidden)]).increment()
        }

        #expect(context.metricRecords == [
            MetricRecord(kind: .counter, label: Self.metricLabel, dimensions: [MetricDimension(key: Self.key, value: Self.forbidden)]),
        ])
        #expect(context.leaks(forbidding: [Self.forbidden]) == [TelemetryLeak(place: place, forbidden: Self.forbidden)])
    }

    @Test("clean telemetry in each place gives no issue")
    func cleanTelemetryGivesNoIssue() async throws {
        let context = try await TelemetryCapture.run(forbidding: [Self.forbidden]) { context in
            Self.recordTelemetry(value: Self.safeValue)
            return context
        }

        #expect(context.places == Self.places(for: Self.safeValue))
        #expect(context.leaks(forbidding: [Self.forbidden]) == [])
    }

    @Test("each log record keeps the label of the logger that wrote it")
    func eachLogRecordKeepsTheLabelOfItsLogger() async throws {
        let context = try await TelemetryCapture.run(forbidding: [Self.forbidden]) { context in
            Logger(label: Self.loggerLabel).info("\(Self.safeMessage)")
            Logger(label: Self.otherLoggerLabel).info("\(Self.safeMessage)")
            return context
        }

        #expect(context.logRecords.map(\.label) == [Self.loggerLabel, Self.otherLoggerLabel])
    }

    @Test("the logger of the context writes its label on each record")
    func theLoggerOfTheContextWritesItsLabel() async throws {
        let context = try await TelemetryCapture.run(forbidding: [Self.forbidden]) { context in
            context.logger.info("\(Self.safeMessage)", metadata: [Self.key: "\(Self.safeValue)"])
            return context
        }

        #expect(context.logRecords == [
            TelemetryCapture.LogRecord(
                level: .info,
                message: "\(Self.safeMessage)",
                metadata: [Self.key: "\(Self.safeValue)"],
                label: TelemetryCapture.loggerLabel
            ),
        ])
    }

    @Test("two captures that run at the same time each see only their own records")
    func parallelCapturesSeeOnlyTheirOwnRecords() async throws {
        let firstValue = "first-3b7c"
        let secondValue = "second-9d2e"
        let opened = Rendezvous(parties: 2)
        let recorded = Rendezvous(parties: 2)

        async let first = Self.captureRecords(of: firstValue, opened: opened, recorded: recorded)
        async let second = Self.captureRecords(of: secondValue, opened: opened, recorded: recorded)
        let (firstContext, secondContext) = try await (first, second)

        #expect(firstContext.places == Self.places(for: firstValue))
        #expect(secondContext.places == Self.places(for: secondValue))
    }

    /// Runs `body` in a capture that forbids ``forbidden``, and expects the
    /// issue that names `place`.
    ///
    /// - Parameters:
    ///   - place: The place that the issue must name.
    ///   - body: The code that writes the forbidden string.
    /// - Returns: The context of the capture, to inspect after the run.
    /// - Throws: An error when the capture gives no context.
    private static func captureWithKnownIssue(
        at place: TelemetryPlace,
        _ body: (TelemetryCapture.Context) async throws -> Void
    ) async throws -> TelemetryCapture.Context {
        var captured: TelemetryCapture.Context?
        try await withKnownIssue {
            captured = try await TelemetryCapture.run(forbidding: [forbidden]) { context in
                try await body(context)
                return context
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains(place.description) }
        }
        return try #require(captured)
    }

    /// Runs one capture that writes `value` in each place, while a second
    /// capture is open at the same time.
    ///
    /// - Parameters:
    ///   - value: The value that this capture writes.
    ///   - opened: The rendezvous that holds the capture until both captures
    ///     are open.
    ///   - recorded: The rendezvous that holds the capture until both captures
    ///     wrote their records.
    /// - Returns: The context of the capture.
    /// - Throws: No error; the body throws none.
    private static func captureRecords(
        of value: String,
        opened: Rendezvous,
        recorded: Rendezvous
    ) async throws -> TelemetryCapture.Context {
        try await TelemetryCapture.run(forbidding: []) { context in
            await opened.arrive()
            recordTelemetry(value: value)
            await recorded.arrive()
            return context
        }
    }

    /// Writes `value` into one span attribute, one span link attribute, one
    /// span event attribute, the description and one attribute of one
    /// recorded error, the span status message, one log message, the error of
    /// that log record and one metric dimension, through the global tracer, a
    /// new logger and a new counter.
    ///
    /// - Parameter value: The value to write.
    private static func recordTelemetry(value: String) {
        InstrumentationSystem.tracer.withSpan(spanName) { span in
            span.attributes[key] = value
            span.addLink(SpanLink(context: .topLevel, attributes: [key: .string(value)]))
            span.addEvent(SpanEvent(name: eventName, attributes: [key: .string(value)]))
            span.recordError(ProbeError(description: value), attributes: [key: .string(value)])
            span.setStatus(SpanStatus(code: .error, message: value))
        }
        Logger(label: loggerLabel).info("\(value)", error: ProbeError(description: value))
        Metrics.Counter(label: metricLabel, dimensions: [(key, value)]).increment()
    }

    /// The places that ``recordTelemetry(value:)`` writes, in the order of
    /// ``TelemetryCapture/Context/places``.
    ///
    /// - Parameter value: The value that the records carry.
    /// - Returns: The span, log and metric places.
    private static func places(for value: String) -> [TelemetryPlace] {
        [
            .spanName(spanName),
            .spanAttribute(span: spanName, key: key, value: value),
            .spanLinkAttribute(span: spanName, key: key, value: value),
            .spanEventName(span: spanName, event: eventName),
            .spanEventAttribute(span: spanName, event: eventName, key: key, value: value),
            .spanError(span: spanName, description: value),
            .spanErrorAttribute(span: spanName, key: key, value: value),
            .spanStatusMessage(span: spanName, message: value),
            .logMessage(level: .info, message: value),
            .logError(level: .info, description: value),
            .metricName(metricLabel),
            .metricDimension(metric: metricLabel, key: key, value: value),
        ]
    }
}

/// An error whose description is the text that the test gives it.
private struct ProbeError: Error, Equatable, CustomStringConvertible {
    /// The text that `String(describing:)` gives for the error.
    let description: String
}

/// Holds each caller until the given count of callers arrived.
private actor Rendezvous {
    /// The count of callers that release each other.
    private let parties: Int

    /// The callers that wait for the others.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Makes a rendezvous for `parties` callers.
    ///
    /// - Parameter parties: The count of callers that release each other.
    init(parties: Int) {
        self.parties = parties
    }

    /// Waits until each of the callers arrived.
    func arrive() async {
        if waiting.count + 1 == parties {
            for continuation in waiting {
                continuation.resume()
            }
            waiting.removeAll()
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }
}
