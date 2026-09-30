@testable import FoundationModelsExtras
import InMemoryTracing
import Logging
import TelemetryTestSupport
import Testing
import Tracing

/// ``TracedCall`` opens one span and writes one "enter" log record before the
/// body starts. It writes nothing more when the body ends, returns or throws.
/// Thus a body that never returns still leaves its "enter" record.
@Suite("TracedCall: one span and one enter log record for each call", .timeLimit(.minutes(1)))
struct TracedCallTests {
    /// The name of the span that each call opens.
    private static let spanName = "probe.call"

    /// The attribute key that each call sets on its span.
    private static let attributeKey = "probe.id"

    /// The attribute value that each call sets on its span.
    private static let attributeValue = "probe-id-42"

    /// The metadata key that each caller gives.
    private static let metadataKey = "probe.request"

    /// The metadata value that each caller gives.
    private static let metadataValue = "request-7"

    /// The label of each logger that a test makes.
    private static let loggerLabel = "probe.logger"

    /// The content that no place of the telemetry may carry.
    private static let forbidden = "caller-content-8c4f"

    /// The message of each "enter" record.
    private static let enterMessage = "enter probe.call"

    /// The metadata that each caller gives.
    private static var callerMetadata: Logger.Metadata {
        [metadataKey: "\(metadataValue)"]
    }

    @Test("one call gives one finished span and one enter record that the body sees before it runs")
    func oneCallGivesOneSpanAndOneEnterRecord() async throws {
        let (context, recordsSeenByBody) = try await TelemetryCapture.run(forbidding: []) { context in
            let records = try await Self.run(logger: context.logger) { _ in context.logRecords }
            return (context, records)
        }

        #expect(recordsSeenByBody.map(\.level) == [TracedCall.enterLevel])
        #expect(recordsSeenByBody.map(\.message) == ["\(Self.enterMessage)"])
        #expect(context.logRecords == recordsSeenByBody)
        let span = try #require(context.spans.first)
        #expect(recordsSeenByBody.map(\.metadata) == [Self.enterMetadata(of: span)])
        #expect(context.spans.count == 1)
        #expect(span.operationName == Self.spanName)
        #expect(span.attributes.get(Self.attributeKey) == .string(Self.attributeValue))
        #expect(span.errors.isEmpty)
    }

    @Test("a body that never returns still leaves its enter record, and the cancel ends the span")
    func aBodyThatNeverReturnsLeavesItsEnterRecord() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
            let logger = Logger(label: Self.loggerLabel) { _ in
                SignalingLogHandler(target: context.logger, signal: enteredSignal)
            }
            // The test never yields to this stream and never finishes it. Only
            // the cancel of the call stops the wait of the body.
            let (neverResumed, neverResumedContinuation) = AsyncStream<Void>.makeStream()
            let call = Task {
                try await Self.run(logger: logger) { _ in
                    for await _ in neverResumed {}
                    try Task.checkCancellation()
                }
            }

            var signals = entered.makeAsyncIterator()
            _ = await signals.next()
            #expect(context.logRecords.map(\.message) == ["\(Self.enterMessage)"])
            #expect(context.spans.isEmpty)

            call.cancel()
            await #expect(throws: CancellationError.self) { try await call.value }
            withExtendedLifetime(neverResumedContinuation) {}

            #expect(context.logRecords.count == 1)
            let span = try #require(context.spans.first)
            #expect(context.spans.count == 1)
            #expect(span.errors.count == 1)
        }
    }

    @Test("a thrown error is recorded on the span and rethrown, with no second log record")
    func aThrownErrorIsRecordedAndRethrown() async throws {
        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await #expect(throws: ProbeError.failed) {
                try await Self.run(logger: context.logger) { _ in throw ProbeError.failed }
            }
            return context
        }

        #expect(context.logRecords.map(\.message) == ["\(Self.enterMessage)"])
        let span = try #require(context.spans.first)
        #expect(context.spans.count == 1)
        #expect(span.errors.map { $0.error as? ProbeError } == [.failed])
    }

    @Test("content that the body returns reaches no span, log record or metric")
    func contentThatTheBodyReturnsReachesNoTelemetry() async throws {
        let context = try await TelemetryCapture.run(forbidding: [Self.forbidden]) { context in
            let output = try await Self.run(logger: Logger(label: Self.loggerLabel)) { _ in Self.forbidden }
            #expect(output == Self.forbidden)
            return context
        }

        #expect(context.spans.count == 1)
        #expect(context.logRecords.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]).isEmpty)
    }

    @Test("the span records the description of an error that the body throws, thus the capture finds content in it")
    func contentInAThrownErrorReachesTheSpan() async throws {
        let error = ProbeError.carrying(Self.forbidden)
        let leak = TelemetryLeak(
            place: .spanError(span: Self.spanName, description: String(describing: error)),
            forbidden: Self.forbidden
        )
        var captured: TelemetryCapture.Context?

        try await withKnownIssue {
            captured = try await TelemetryCapture.run(forbidding: [Self.forbidden]) { context in
                await #expect(throws: error) {
                    try await Self.run(logger: Logger(label: Self.loggerLabel)) { _ in throw error }
                }
                return context
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue == leak.description }
        }

        let context = try #require(captured)
        #expect(context.logRecords.count == 1)
        #expect(context.leaks(forbidding: [Self.forbidden]) == [leak])
    }

    @Test("a tracer that injects a W3C traceparent gives the trace id and the span id to the record")
    func aTraceparentGivesTheIdsToTheRecord() async throws {
        let tracer = W3CInMemoryTracer()
        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.run(tracer: tracer, logger: context.logger) { _ in }
            return context
        }

        let span = try #require(tracer.finishedSpans.first)
        let record = try #require(context.logRecords.first)
        #expect(context.spans.isEmpty)
        #expect(context.logRecords.count == 1)
        #expect(record.metadata == Self.enterMetadata(of: span))
    }

    @Test("in a capture with no explicit tracer, the enter record holds the trace id and the span id of its span")
    func aCaptureGivesTheIdsToTheRecord() async throws {
        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.run(logger: context.logger) { _ in }
            return context
        }

        let span = try #require(context.spans.first)
        let record = try #require(context.logRecords.first)
        #expect(context.spans.count == 1)
        #expect(context.logRecords.count == 1)
        #expect(record.metadata[ExtrasTelemetry.LogMetadataKey.traceID] == "\(span.traceID)")
        #expect(record.metadata[ExtrasTelemetry.LogMetadataKey.spanID] == "\(span.spanID)")
        #expect(SpanIdentity(traceID: span.traceID, spanID: span.spanID) != nil)
    }

    @Test("the enter record uses the names of the telemetry vocabulary")
    func theEnterRecordUsesTheVocabulary() {
        #expect(ExtrasTelemetry.EnterRecord.message(forSpanNamed: Self.spanName) == Self.enterMessage)
        #expect(ExtrasTelemetry.LogMetadataKey.traceID == "trace.id")
        #expect(ExtrasTelemetry.LogMetadataKey.spanID == "span.id")
    }

    /// The metadata of the "enter" record of one call: the caller metadata,
    /// plus the trace id and the span id of the span of the call.
    ///
    /// - Parameter span: The finished span of the call.
    /// - Returns: The metadata that the record must hold.
    private static func enterMetadata(of span: FinishedInMemorySpan) -> Logger.Metadata {
        var metadata = callerMetadata
        metadata[ExtrasTelemetry.LogMetadataKey.traceID] = "\(span.traceID)"
        metadata[ExtrasTelemetry.LogMetadataKey.spanID] = "\(span.spanID)"
        return metadata
    }

    /// Runs `body` through ``TracedCall`` with the span name, the attribute
    /// and the caller metadata of the suite.
    ///
    /// - Parameters:
    ///   - tracer: The tracer of the call, or `nil` for the global tracer.
    ///   - logger: The logger of the "enter" record.
    ///   - body: The call.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    private static func run<Output>(
        tracer: (any Tracer)? = nil,
        logger: Logger,
        _ body: (any Span) async throws -> Output
    ) async throws -> Output {
        try await TracedCall.run(
            spanName,
            tracer: tracer,
            logger: logger,
            attributes: { $0[attributeKey] = attributeValue },
            metadata: callerMetadata,
            body
        )
    }
}

/// The error that a probe body throws.
private enum ProbeError: Error, Equatable {
    /// A failure with no content.
    case failed

    /// A failure that carries content of the caller.
    case carrying(String)
}

/// A log handler that sends each record to a target logger, and then yields
/// one signal.
private struct SignalingLogHandler: LogHandler {
    /// The logger that keeps each record.
    let target: Logger

    /// The stream that gets one element for each record.
    let signal: AsyncStream<Void>.Continuation

    /// The metadata of the logger that holds this handler.
    var metadata: Logger.Metadata = [:]

    /// The lowest level that the logger sends to this handler.
    var logLevel: Logger.Level = .trace

    /// Reads or writes one metadata value of the logger.
    ///
    /// - Parameter key: The metadata key.
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Sends `event` to ``target``, then yields to ``signal``.
    ///
    /// - Parameter event: The log record.
    func log(event: LogEvent) {
        target.log(
            level: event.level,
            event.message,
            metadata: event.metadata,
            source: event.source,
            file: event.file,
            function: event.function,
            line: event.line
        )
        signal.yield()
    }
}
