import Tracing
import ULID

/// Opens the one span of a mounted tool call, and records the tool-call
/// metrics of the call.
///
/// The span has the tool name, the session and the run kind. It has no tool
/// arguments, no tool output and no description of a tool error: a span
/// leaves the process through the tracing backend of the host, so it carries
/// names and identifiers only. When the tool throws, the span gets the error
/// status and the ``ExtrasTelemetry/AttributeKey/errorType`` of the error from
/// ``TracedCall``, never the description of the error.
/// ``withSpan(tracer:toolName:sessionID:runKind:_:)`` opens the span through
/// ``TracedCall``, so each call also writes one "enter" log record when it
/// starts. A tool call can suspend for a long time, and the record shows a
/// call that hangs.
///
/// The caller writes the outcome with ``record(outcome:on:)``, with
/// ``record(outcomeOf:on:)`` for the terminal event of a run, or with
/// ``record(settledTerminal:on:)`` for a background call, because only the
/// caller knows how the call ended. That record also adds one count to
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

        /// The call starts a background run and waits for it up to the end
        /// of its settle period, so the span and the duration cover the start
        /// and that wait. A run that continues after the settle period
        /// settles later, outside the span.
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
    /// - Throws: The error of `body`. The span gets the error status and the
    ///   `error.type` of the error first, never its description.
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
    /// The span ends when the body of
    /// ``withSpan(tracer:toolName:sessionID:runKind:_:)`` returns. Thus the
    /// caller records the outcome as the last step of that body, after all
    /// the work of the call, so the duration and the span measure the same
    /// interval. For a ``ToolRunKind/background`` call, the caller records
    /// the outcome after the wait up to the end of the settle period, so the
    /// duration measures the start and that wait, as the span does.
    ///
    /// The span attribute and the metric dimensions carry the bounded
    /// telemetry value of the outcome from
    /// ``ExtrasTelemetry/telemetryOutcome(of:)``, never the text of an
    /// ``OperationOutcome/other(_:)`` outcome.
    ///
    /// - Parameters:
    ///   - outcome: How the call ended.
    ///   - call: The open call.
    static func record(outcome: OperationOutcome, on call: Call) {
        call.span.attributes[ExtrasTelemetry.AttributeKey.outcome] = ExtrasTelemetry.telemetryOutcome(of: outcome).rawValue
        ExtrasTelemetry.recordToolCall(
            toolName: call.toolName, outcome: outcome, duration: ContinuousClock.now - call.start)
    }

    /// The outcome that ``record(outcomeOf:on:)`` records for a terminal
    /// event with no outcome.
    ///
    /// It is ``OperationOutcome/lost``, because the event does not tell how
    /// the call ended: the outcome is unknowable. Its telemetry value is
    /// ``QueueOutcome/lost``.
    static let outcomeOfTerminalWithNoOutcome = OperationOutcome.lost

    /// Writes the outcome of the terminal event of the call onto its span,
    /// and records one count and one duration of the call.
    ///
    /// The call records exactly one count and one duration also when
    /// `terminal` has no outcome. The outcome is then
    /// ``outcomeOfTerminalWithNoOutcome``.
    ///
    /// - Parameters:
    ///   - terminal: The terminal event of the run of the call.
    ///   - call: The open call.
    static func record(outcomeOf terminal: OperationEvent, on call: Call) {
        record(outcome: terminal.outcome ?? outcomeOfTerminalWithNoOutcome, on: call)
    }

    /// The outcome that ``record(settledTerminal:on:)`` records for a
    /// background call that answers with the pending envelope.
    ///
    /// It is ``OperationOutcome/succeeded``, because the start of the run
    /// succeeded. The run settles later with its own terminal event.
    static let outcomeOfStartedRun = OperationOutcome.succeeded

    /// Writes `tool.settled_inline` and the outcome of a
    /// ``ToolRunKind/background`` call onto its span, and records one count
    /// and one duration of the call.
    ///
    /// - Parameters:
    ///   - terminal: The terminal event of a run that settled inside its
    ///     settle period, or `nil` when the call answers with the pending
    ///     envelope. A terminal event gives `tool.settled_inline=true` and
    ///     its own outcome, also when the run plane settled the run while its
    ///     body still runs. `nil` gives `tool.settled_inline=false` and
    ///     ``outcomeOfStartedRun``.
    ///   - call: The open call.
    static func record(settledTerminal terminal: OperationEvent?, on call: Call) {
        call.span.attributes[ExtrasTelemetry.AttributeKey.settledInline] = terminal != nil
        guard let terminal else {
            record(outcome: outcomeOfStartedRun, on: call)
            return
        }
        record(outcomeOf: terminal, on: call)
    }

    /// Gives back the result of a call as the body of
    /// ``withSpan(tracer:toolName:sessionID:runKind:_:)`` must see it.
    ///
    /// The body gives a timeout back as a value, so the span does not record
    /// the timeout as an error: a timeout is an outcome of the call, not a
    /// failure. The body throws each other error, so the span gets the error
    /// status for it. The caller throws the timeout after the span ends.
    ///
    /// - Parameter result: The result of the call.
    /// - Returns: The output of the tool, or the timeout as a failure.
    /// - Throws: Each error of the call that is not a timeout.
    static func spanResult(of result: Result<String, any Error>) throws -> Result<String, any Error> {
        switch result {
        case .failure(ToolMountError.timedOut):
            return result
        case .success, .failure:
            return .success(try result.get())
        }
    }
}
