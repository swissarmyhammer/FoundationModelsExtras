import Tracing
import ULID

/// Opens the one span of a mounted tool call, and records the tool-call
/// metrics of the call.
///
/// The span has the tool name, the session and the run kind. It has no tool
/// arguments and no tool output: a span leaves the process through the
/// tracing backend of the host, so it carries names and identifiers only.
/// ``withSpan(tracer:toolName:sessionID:runKind:_:)`` opens the span through
/// ``TracedCall``, so each call also writes one "enter" log record when it
/// starts. A tool call can suspend for a long time, and the record shows a
/// call that hangs.
///
/// The caller writes the outcome with ``record(outcome:on:)``, because only
/// the caller knows how the call ended. That record also adds one count to
/// the counter ``ExtrasTelemetry/MetricName/toolCalls`` and one duration to
/// the timer ``ExtrasTelemetry/MetricName/toolDuration``. Both metrics have
/// the tool name and the outcome as their only dimensions. The span keeps the
/// run kind: a metric dimension for it would split the count of one tool into
/// two series, and a tool can choose its mode for each call.
enum ToolCallSpan {
    /// How much of the call the span and the duration measure.
    enum ToolRunKind: String {
        /// The call runs in band, so the span and the duration cover the whole
        /// call.
        case foreground

        /// The call starts a background run, so the span and the duration
        /// cover only the start. The run settles later.
        case background
    }

    /// The open tool span of one call, and the facts that the tool-call
    /// metrics need.
    struct Call {
        /// The tool span.
        let span: any Span

        /// The model-facing name of the tool.
        let toolName: String

        /// The time when the call started.
        let start: ContinuousClock.Instant
    }

    /// Runs `body` inside one tool span, and writes one "enter" log record
    /// before `body` starts.
    ///
    /// The logger of the record is made at call time, so that it writes
    /// through the logging backend that is in effect when the call starts.
    ///
    /// - Parameters:
    ///   - tracer: The tracer of the session, or `nil` to use
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - toolName: The model-facing name of the tool.
    ///   - sessionID: The session that the call runs in.
    ///   - runKind: How much of the call the span measures.
    ///   - body: The call. It gets the open call, to record the outcome.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records it first.
    nonisolated(nonsending) static func withSpan<Output>(
        tracer: (any Tracer)?,
        toolName: String,
        sessionID: ULID,
        runKind: ToolRunKind,
        _ body: nonisolated(nonsending) (Call) async throws -> Output
    ) async throws -> Output {
        let start = ContinuousClock.now
        return try await TracedCall.run(
            ExtrasTelemetry.SpanName.tool,
            tracer: tracer,
            logger: ExtrasTelemetry.makeLogger(),
            attributes: { attributes in
                attributes[ExtrasTelemetry.AttributeKey.toolName] = toolName
                attributes[ExtrasTelemetry.AttributeKey.sessionID] = sessionID.description
                attributes[ExtrasTelemetry.AttributeKey.runKind] = runKind.rawValue
            },
            metadata: [
                ExtrasTelemetry.LogMetadataKey.toolName: .string(toolName),
                ExtrasTelemetry.LogMetadataKey.sessionID: .string(sessionID.description),
            ]
        ) { span in
            try await body(Call(span: span, toolName: toolName, start: start))
        }
    }

    /// Writes the outcome of the call onto its span, and records one count
    /// and one duration of the call.
    ///
    /// The duration is the time from the start of the call to this record.
    /// For a ``ToolRunKind/background`` call, the caller records the outcome
    /// when the run has started, so the duration measures the start only, as
    /// the span does.
    ///
    /// - Parameters:
    ///   - outcome: How the call ended.
    ///   - call: The open call.
    static func record(outcome: OperationOutcome, on call: Call) {
        call.span.attributes[ExtrasTelemetry.AttributeKey.outcome] = outcome.rawValue
        ExtrasTelemetry.recordToolCall(
            toolName: call.toolName, outcome: outcome, duration: ContinuousClock.now - call.start)
    }
}
