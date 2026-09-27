import Tracing
import ULID

/// Opens the one span of a mounted tool call.
///
/// The span has the tool name, the session and the run kind. It has no tool
/// arguments and no tool output: a span leaves the process through the
/// tracing backend of the host, so it carries names and identifiers only.
/// The caller writes the outcome with ``record(outcome:on:)``, because only
/// the caller knows how the call ended.
enum ToolCallSpan {
    /// The name of each tool span.
    static let name = "FoundationModelsRouter.tool"

    /// The attribute keys of a tool span.
    enum AttributeKey {
        /// The model-facing name of the tool.
        static let toolName = "tool.name"

        /// The session that the call runs in.
        static let sessionID = "session.id"

        /// The ``ToolRunKind`` of the call.
        static let runKind = "tool.run_kind"

        /// The ``OperationOutcome`` of the call.
        static let outcome = "tool.outcome"
    }

    /// How much of the call the span measures.
    enum ToolRunKind: String {
        /// The call runs in band, so the span covers the whole call.
        case foreground

        /// The call starts a background run, so the span covers only the
        /// start. The run settles later.
        case background
    }

    /// Runs `body` inside one tool span.
    ///
    /// - Parameters:
    ///   - tracer: The tracer of the session, or `nil` to use
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - toolName: The model-facing name of the tool.
    ///   - sessionID: The session that the call runs in.
    ///   - runKind: How much of the call the span measures.
    ///   - body: The call. It gets the open span, to record the outcome.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records it first.
    static func withSpan<Output>(
        tracer: (any Tracer)?,
        toolName: String,
        sessionID: ULID,
        runKind: ToolRunKind,
        _ body: (any Span) async throws -> Output
    ) async throws -> Output {
        try await (tracer ?? InstrumentationSystem.tracer).withSpan(name, ofKind: .internal) { span in
            span.attributes[AttributeKey.toolName] = toolName
            span.attributes[AttributeKey.sessionID] = sessionID.description
            span.attributes[AttributeKey.runKind] = runKind.rawValue
            return try await body(span)
        }
    }

    /// Writes the outcome of the call onto its span.
    ///
    /// - Parameters:
    ///   - outcome: How the call ended.
    ///   - span: The tool span.
    static func record(outcome: OperationOutcome, on span: any Span) {
        span.attributes[AttributeKey.outcome] = outcome.rawValue
    }
}
