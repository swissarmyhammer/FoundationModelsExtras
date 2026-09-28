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
        #expect(recordsSeenByBody.map(\.metadata) == [Self.callerMetadata])
        #expect(context.logRecords == recordsSeenByBody)
        let span = try #require(context.spans.first)
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

    @Test("content that only the body holds reaches no span, log record or metric")
    func contentOfTheBodyReachesNoTelemetry() async throws {
        let context = try await TelemetryCapture.run(forbidding: [Self.forbidden]) { context in
            let output = try await Self.run(logger: Logger(label: Self.loggerLabel)) { _ in Self.forbidden }
            #expect(output == Self.forbidden)
            await #expect(throws: ProbeError.carrying(Self.forbidden)) {
                try await Self.run(logger: Logger(label: Self.loggerLabel)) { _ in
                    throw ProbeError.carrying(Self.forbidden)
                }
            }
            return context
        }

        #expect(context.spans.count == 2)
        #expect(context.logRecords.count == 2)
        #expect(context.leaks(forbidding: [Self.forbidden]).isEmpty)
    }

    @Test("a tracer that injects a W3C traceparent gives the trace id and the span id to the record")
    func aTraceparentGivesTheIdsToTheRecord() async throws {
        let tracer = TraceparentTracer()
        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.run(tracer: tracer, logger: context.logger) { _ in }
            return context
        }

        let span = try #require(tracer.inner.finishedSpans.first)
        let record = try #require(context.logRecords.first)
        #expect(context.logRecords.count == 1)
        var expectedMetadata = Self.callerMetadata
        expectedMetadata[ExtrasTelemetry.EnterRecord.MetadataKey.traceID] = "\(span.traceID)"
        expectedMetadata[ExtrasTelemetry.EnterRecord.MetadataKey.spanID] = "\(span.spanID)"
        #expect(record.metadata == expectedMetadata)
    }

    @Test("the enter record uses the names of the telemetry vocabulary")
    func theEnterRecordUsesTheVocabulary() {
        #expect(ExtrasTelemetry.EnterRecord.message(forSpanNamed: Self.spanName) == Self.enterMessage)
        #expect(ExtrasTelemetry.EnterRecord.MetadataKey.traceID == "trace.id")
        #expect(ExtrasTelemetry.EnterRecord.MetadataKey.spanID == "span.id")
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

/// ``SpanIdentity`` reads the trace id and the span id from a W3C
/// `traceparent` value, and refuses a value that the W3C format does not
/// allow.
@Suite("SpanIdentity: the ids of a W3C traceparent value")
struct SpanIdentityTests {
    /// A trace id in the W3C format.
    private static let traceID = "4bf92f3577b34da6a3ce929d0e0e4736"

    /// A span id in the W3C format.
    private static let spanID = "00f067aa0ba902b7"

    @Test("a valid traceparent gives its trace id and its span id")
    func aValidTraceparentGivesItsIds() throws {
        let identity = try #require(SpanIdentity(traceparent: "00-\(Self.traceID)-\(Self.spanID)-01"))

        #expect(identity.traceID == Self.traceID)
        #expect(identity.spanID == Self.spanID)
    }

    @Test(
        "a traceparent that the W3C format does not allow gives no ids",
        arguments: [
            "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01",
            "00-\(traceID)-\(spanID)",
            "00-\(traceID)-\(spanID)-01-00",
            "00-\(traceID.dropLast())-\(spanID)-01",
            "00-\(traceID)-\(spanID)0-01",
            "00-00000000000000000000000000000000-\(spanID)-01",
            "00-\(traceID)-0000000000000000-01",
            "ff-\(traceID)-\(spanID)-01",
            "00-\(traceID)-\(spanID.dropLast())g-01",
            "",
        ]
    )
    func anInvalidTraceparentGivesNoIds(traceparent: String) {
        #expect(SpanIdentity(traceparent: traceparent) == nil)
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

/// A tracer that keeps its spans in an in-memory tracer, and injects the span
/// context as a W3C `traceparent` value, as an OpenTelemetry tracer does.
private struct TraceparentTracer: Tracer {
    /// The count of hexadecimal digits in one 64-bit part of an id.
    private static let hexDigitsPerPart = 16

    /// The radix of hexadecimal digits.
    private static let hexRadix = 16

    /// The in-memory tracer that makes and keeps the spans. Its ids have the
    /// W3C format.
    let inner = InMemoryTracer(idGenerator: .init(
        nextTraceID: { hex(randomPart()) + hex(randomPart()) },
        nextSpanID: { hex(randomPart()) }
    ))

    /// Starts a span in the in-memory tracer.
    ///
    /// - Parameters:
    ///   - operationName: The name of the span.
    ///   - context: The parent context.
    ///   - kind: The kind of the span.
    ///   - instant: The start time.
    ///   - function: The function that starts the span.
    ///   - fileID: The file that starts the span.
    ///   - line: The line that starts the span.
    /// - Returns: The span.
    func startSpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> InMemorySpan {
        inner.startSpan(
            operationName,
            context: context(),
            ofKind: kind,
            at: instant(),
            function: function,
            file: fileID,
            line: line
        )
    }

    /// Gives the active span that `context` names.
    ///
    /// - Parameter context: The context of the span.
    /// - Returns: The span, or `nil` when no active span has that context.
    func activeSpan(identifiedBy context: ServiceContext) -> InMemorySpan? {
        inner.activeSpan(identifiedBy: context)
    }

    /// Flushes the in-memory tracer.
    func forceFlush() {
        inner.forceFlush()
    }

    /// Reads a context from `carrier` through the in-memory tracer.
    ///
    /// - Parameters:
    ///   - carrier: The carrier.
    ///   - context: The context to fill.
    ///   - extractor: The reader of the carrier.
    func extract<Carrier, Extract: Extractor>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Extract.Carrier == Carrier {
        inner.extract(carrier, into: &context, using: extractor)
    }

    /// Writes the span context of `context` into `carrier` as a W3C
    /// `traceparent` value.
    ///
    /// - Parameters:
    ///   - context: The context that holds the span context.
    ///   - carrier: The carrier.
    ///   - injector: The writer of the carrier.
    func inject<Carrier, Inject: Injector>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject.Carrier == Carrier {
        guard let spanContext = context.inMemorySpanContext else {
            return
        }
        let traceparent = "00-\(spanContext.traceID)-\(spanContext.spanID)-01"
        injector.inject(traceparent, forKey: SpanIdentity.traceparentField, into: &carrier)
    }

    /// Gives a random part of an id that is not zero.
    ///
    /// - Returns: The part.
    private static func randomPart() -> UInt64 {
        UInt64.random(in: 1 ... UInt64.max)
    }

    /// Gives `part` as lowercase hexadecimal digits, with leading zeros.
    ///
    /// - Parameter part: The part of an id.
    /// - Returns: The digits.
    private static func hex(_ part: UInt64) -> String {
        let digits = String(part, radix: hexRadix)
        return String(repeating: "0", count: hexDigitsPerPart - digits.count) + digits
    }
}
