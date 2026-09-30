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
    /// The record never holds a value or an error of `body`. The span records
    /// each error of `body`, and a telemetry backend exports the description
    /// of that error. Thus `body` must throw no error whose description holds
    /// content.
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
