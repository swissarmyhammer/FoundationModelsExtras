import Logging
import Tracing

/// Runs a call in one span, and writes one "enter" log record when the call
/// starts.
///
/// Rule 8 of the OpenTelemetry design of 2026-09-28, hang detection: a tracing
/// backend exports a span only when the span ends. Thus a call that hangs
/// gives no span, and the backend shows nothing. A call that can suspend for a
/// long time must also write one log record when it starts. The logging
/// backend exports that record at once, so a hung call shows as an "enter"
/// record with no span that ends.
///
/// ``run(_:ofKind:tracer:logger:attributes:metadata:_:)`` writes the record
/// before the body starts, and it writes nothing more. The span records the
/// end, the duration and the error of the call.
///
/// Rule 4 of the same design: a span attribute, a log message and a log
/// metadata value carry ids, names, counts and sizes only. They never carry a
/// prompt, a response, tool arguments, tool output, embed text or an LSP
/// payload, because each record leaves the process through the telemetry
/// backend of the host. The helper obeys rule 4 for the parts that it writes:
/// the message holds only the span name, and the metadata holds only the
/// metadata of the caller and the ids of the span. It never puts a value or an
/// error of the body into the record. The caller must obey rule 4 for the
/// span name, the attributes and the metadata that it gives.
///
/// ```swift
/// let answer = try await TracedCall.run(
///     "Multitool.lsp.request",
///     logger: logger,
///     attributes: { $0["lsp.method"] = method },
///     metadata: ["lsp.request_id": "\(requestID)"]
/// ) { _ in
///     try await server.send(request)
/// }
/// ```
public enum TracedCall {
    /// The level of the "enter" record.
    ///
    /// The level is `.info` and not `.debug`, because `.info` is the default
    /// level of a swift-log logger. Thus the record reaches the logging
    /// backend of the host with no configuration, and hang detection works
    /// by default. The record is short: one span name and some ids.
    public static let enterLevel: Logger.Level = .info

    /// Opens one span, writes one "enter" log record, and then runs `body` in
    /// the span.
    ///
    /// The span ends when `body` returns or throws. When `body` throws, the
    /// span records the error, and this function throws the same error. This
    /// function writes no log record on exit.
    ///
    /// The metadata of the record is `metadata`, plus the W3C trace id and
    /// span id of the new span under
    /// ``ExtrasTelemetry/LogMetadataKey``, when the tracer injects
    /// the span context as a W3C `traceparent` value. An OpenTelemetry tracer
    /// does. The ids replace a caller value with the same key.
    ///
    /// Rule 4: give no content in `spanName`, `attributes` or `metadata`.
    /// The record never holds a value or an error of `body`.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span. The message of the record is
    ///     `enter <spanName>`.
    ///   - kind: The kind of the span.
    ///   - tracer: The tracer of the span, or `nil` to use
    ///     `InstrumentationSystem.tracer` at call time. That tracer is the
    ///     task-local tracer of `withTracer` when one is bound.
    ///   - logger: The logger of the "enter" record.
    ///   - attributes: Sets the attributes of the span before the record is
    ///     written. Ids, names, counts and sizes only.
    ///   - metadata: The metadata of the record. Ids, names, counts and sizes
    ///     only.
    ///   - body: The call. It gets the open span, and it runs on the actor of
    ///     the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records it first.
    public nonisolated(nonsending) static func run<Output>(
        _ spanName: String,
        ofKind kind: SpanKind = .internal,
        tracer: (any Tracer)? = nil,
        logger: Logger,
        attributes: (inout SpanAttributes) -> Void = { _ in },
        metadata: Logger.Metadata = [:],
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async throws -> Output {
        let activeTracer = tracer ?? InstrumentationSystem.tracer
        return try await activeTracer.withSpan(spanName, ofKind: kind) { span in
            span.updateAttributes(attributes)
            logger.log(
                level: enterLevel,
                "\(ExtrasTelemetry.EnterRecord.message(forSpanNamed: spanName))",
                metadata: enterMetadata(metadata, of: span.context, from: activeTracer)
            )
            return try await body(span)
        }
    }

    /// Gives the metadata of the "enter" record of one span.
    ///
    /// - Parameters:
    ///   - metadata: The metadata of the caller.
    ///   - context: The context of the new span.
    ///   - tracer: The tracer that made the span.
    /// - Returns: `metadata`, plus the trace id and the span id of the span
    ///   when the tracer gives them.
    private static func enterMetadata(
        _ metadata: Logger.Metadata,
        of context: ServiceContext,
        from tracer: any Tracer
    ) -> Logger.Metadata {
        guard let identity = SpanIdentity(context: context, tracer: tracer) else {
            return metadata
        }
        var merged = metadata
        merged[ExtrasTelemetry.LogMetadataKey.traceID] = "\(identity.traceID)"
        merged[ExtrasTelemetry.LogMetadataKey.spanID] = "\(identity.spanID)"
        return merged
    }
}

/// The W3C trace id and span id of one span.
///
/// The generic tracing API gives no ids on a span. A tracer gives them only
/// when it injects the span context into a carrier. An OpenTelemetry tracer
/// injects a W3C `traceparent` value, `<version>-<trace id>-<span id>-<flags>`.
/// This type reads the ids from that value.
struct SpanIdentity: Equatable {
    /// The carrier key of the W3C trace context value.
    static let traceparentField = "traceparent"

    /// The separator of the fields of a `traceparent` value.
    private static let fieldSeparator: Character = "-"

    /// The version that the W3C format forbids.
    private static let forbiddenVersion = "ff"

    /// The digits that a field may hold. The W3C format allows lowercase
    /// hexadecimal digits only.
    private static let lowercaseHexDigits = Set("0123456789abcdef")

    /// The digit of an id that is not valid when each digit is this digit.
    private static let zeroDigit: Character = "0"

    /// The count of hexadecimal digits of the version field.
    private static let versionLength = 2

    /// The count of hexadecimal digits of a W3C trace id.
    private static let traceIDLength = 32

    /// The count of hexadecimal digits of a W3C span id.
    private static let spanIDLength = 16

    /// The count of hexadecimal digits of the trace flags field.
    private static let flagsLength = 2

    /// The fields of a `traceparent` value, in their order.
    private enum Field: Int, CaseIterable {
        /// The version of the format.
        case version

        /// The trace id.
        case traceID

        /// The id of the span, which the W3C format calls the parent id.
        case spanID

        /// The trace flags.
        case flags

        /// The count of hexadecimal digits of the field.
        var length: Int {
            switch self {
            case .version: SpanIdentity.versionLength
            case .traceID: SpanIdentity.traceIDLength
            case .spanID: SpanIdentity.spanIDLength
            case .flags: SpanIdentity.flagsLength
            }
        }
    }

    /// The trace id: 32 lowercase hexadecimal digits.
    let traceID: String

    /// The span id: 16 lowercase hexadecimal digits.
    let spanID: String

    /// Reads the ids of the span of `context` from the `traceparent` value
    /// that `tracer` injects.
    ///
    /// - Parameters:
    ///   - context: The context of the span.
    ///   - tracer: The tracer that made the span.
    /// - Returns: `nil` when the tracer injects no valid `traceparent` value.
    init?(context: ServiceContext, tracer: any Tracer) {
        var carrier: [String: String] = [:]
        tracer.inject(context, into: &carrier, using: DictionaryInjector())
        guard let traceparent = carrier[Self.traceparentField] else {
            return nil
        }
        self.init(traceparent: traceparent)
    }

    /// Reads the ids from a W3C `traceparent` value.
    ///
    /// - Parameter traceparent: The value, in the format of version `00`: four
    ///   fields of lowercase hexadecimal digits.
    /// - Returns: `nil` when the value does not have that format, when the
    ///   version is `ff`, or when an id is all zeros.
    init?(traceparent: String) {
        let fields = traceparent
            .split(separator: Self.fieldSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == Field.allCases.count,
              zip(Field.allCases, fields).allSatisfy({ Self.isValid($0, $1) })
        else {
            return nil
        }
        let traceID = fields[Field.traceID.rawValue]
        let spanID = fields[Field.spanID.rawValue]
        guard fields[Field.version.rawValue] != Self.forbiddenVersion,
              !Self.isAllZeros(traceID),
              !Self.isAllZeros(spanID)
        else {
            return nil
        }
        self.traceID = traceID
        self.spanID = spanID
    }

    /// Whether `text` has the length of `field` and holds only lowercase
    /// hexadecimal digits.
    ///
    /// - Parameters:
    ///   - field: The field.
    ///   - text: The text of the field.
    /// - Returns: Whether the text is valid for the field.
    private static func isValid(_ field: Field, _ text: String) -> Bool {
        text.count == field.length && text.allSatisfy(lowercaseHexDigits.contains)
    }

    /// Whether each digit of `id` is zero.
    ///
    /// - Parameter id: The id.
    /// - Returns: Whether the id is all zeros.
    private static func isAllZeros(_ id: String) -> Bool {
        id.allSatisfy { $0 == zeroDigit }
    }
}

/// Writes each injected value into a dictionary.
private struct DictionaryInjector: Injector {
    /// Writes `value` under `key`.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - key: The key.
    ///   - carrier: The dictionary.
    func inject(_ value: String, forKey key: String, into carrier: inout [String: String]) {
        carrier[key] = value
    }
}
