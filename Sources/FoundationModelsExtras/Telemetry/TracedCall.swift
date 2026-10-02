import Logging
import Tracing

/// Runs a call in one span, and writes one "enter" log record when the call
/// starts.
///
/// Hang detection: a tracing backend exports a span only when the span ends.
/// Thus a call that hangs gives no span, and the backend shows nothing. A
/// call that can suspend for a long time must also write one log record when
/// it starts. The logging backend exports that record at once, so a hung call
/// shows as an "enter" record with no span that ends.
///
/// ``run(_:ofKind:tracer:logger:attributes:metadata:_:)`` writes the record
/// before the body starts, and it writes nothing more. The span records the
/// end and the duration of the call, and, when the call throws, the error
/// status and the ``ExtrasTelemetry/AttributeKey/errorType`` of the error.
///
/// The content-safety rule: a span attribute, a log message and a log
/// metadata value carry ids, names, counts and sizes only. They never carry a
/// prompt, a response, tool arguments, tool output, embed text or an LSP
/// payload, because each record leaves the process through the telemetry
/// backend of the host. The helper obeys this rule for the parts that it
/// writes: the message holds only the span name, and the metadata holds only
/// the metadata of the caller and the ids of the span. It never puts a value
/// or an error of the body into the record. The span never gets the
/// description of an error of the body: a description can hold content, and
/// a telemetry backend exports each error that a span records. The caller
/// must obey this rule for the span name, the attributes and the metadata
/// that it gives.
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
    /// span gets the error status and an `error.type` attribute, and this
    /// function throws the same error. The `error.type` is the type name of the
    /// error, then its enum case name when reflection shows one. The span
    /// records no error event, no status message and no description of the
    /// error. This function writes no log record on exit.
    ///
    /// The metadata of the record is `metadata`, plus the W3C trace id and
    /// span id of the new span under
    /// ``ExtrasTelemetry/LogMetadataKey``, when the tracer injects
    /// the span context as a W3C `traceparent` value. An OpenTelemetry tracer
    /// does. The ids replace a caller value with the same key.
    ///
    /// Give no content in `spanName`, `attributes` or `metadata`: a
    /// telemetry backend exports each of them out of the process.
    /// The record never holds a value or an error of `body`, and the span
    /// never holds the description of an error of `body`. Thus `body` can
    /// throw an error whose description holds content.
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
    /// - Throws: The error of `body`. The span gets the error status and the
    ///   `error.type` of the error first, never its description.
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
        // The body gives its error back as a value, so `withSpan` sees no
        // error. `withSpan` records each error that it sees with
        // `recordError`, and a telemetry backend exports the description of
        // that error.
        let result: Result<Output, any Error> = await activeTracer.withSpan(spanName, ofKind: kind) { span in
            span.updateAttributes(attributes)
            logger.log(
                level: enterLevel,
                "\(ExtrasTelemetry.EnterRecord.message(forSpanNamed: spanName))",
                metadata: enterMetadata(metadata, of: span.context, from: activeTracer)
            )
            do {
                return .success(try await body(span))
            } catch {
                recordFailure(of: error, on: span)
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Gives `span` the error status and the
    /// ``ExtrasTelemetry/AttributeKey/errorType`` of `error`.
    ///
    /// The span gets no error event, no status message and no description of
    /// the error, because a description can hold content.
    ///
    /// - Parameters:
    ///   - error: The error that `body` threw.
    ///   - span: The span of the call.
    private static func recordFailure(of error: any Error, on span: any Span) {
        span.setStatus(SpanStatus(code: .error))
        span.attributes[ExtrasTelemetry.AttributeKey.errorType] = ExtrasTelemetry.errorType(of: error)
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
