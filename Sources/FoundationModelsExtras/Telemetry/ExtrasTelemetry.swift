import Logging
import Metrics

/// The telemetry vocabulary of the core target: the span names, the attribute
/// keys, the metric names and the log metadata keys, and the logger and the
/// tool-call metrics that use them.
///
/// Rule 3 of the OpenTelemetry design of 2026-09-28: each package keeps all of
/// its telemetry names in one vocabulary file. No other source file of the core
/// target writes a telemetry name as a string literal.
///
/// Each span name, logger label and metric name starts with the module name. A
/// metadata key of a log record has the dotted form of an attribute key, for
/// example `trace.id`. The core target uses the swift-log
/// and swift-metrics APIs only, and it bootstraps no backend. The executables
/// of the family bootstrap the backend. Until one does, each metric does
/// nothing, and each logger writes through the default handler of swift-log.
///
/// A metric dimension carries the tool name and the outcome only. It never
/// carries tool arguments or tool output, because a dimension leaves the
/// process through the metrics backend of the host.
enum ExtrasTelemetry {
    /// The label of each logger of the core target.
    static let logLabel = "FoundationModelsExtras"

    /// The span names of the core target.
    enum SpanName {
        /// The span of one mounted tool call.
        static let tool = "FoundationModelsExtras.tool"
    }

    /// The attribute keys of the spans of the core target.
    enum AttributeKey {
        /// The model-facing name of the tool.
        static let toolName = "tool.name"

        /// The session that the call runs in.
        static let sessionID = "session.id"

        /// The ``ToolCallSpan/ToolRunKind`` of the call.
        static let runKind = "tool.run_kind"

        /// The ``OperationOutcome`` of the call.
        static let outcome = "tool.outcome"
    }

    /// The metric names of the core target.
    enum MetricName {
        /// The counter that counts each tool call.
        static let toolCalls = "FoundationModelsExtras.tool.calls"

        /// The timer that records the duration of each tool call.
        static let toolDuration = "FoundationModelsExtras.tool.duration"
    }

    /// The metadata keys of the log records of the core target.
    enum LogMetadataKey {
        /// The W3C trace id of the span of a call.
        static let traceID = "trace.id"

        /// The W3C span id of the span of a call.
        static let spanID = "span.id"

        /// The model-facing name of the tool. It has the same key as the span
        /// attribute.
        static let toolName = AttributeKey.toolName

        /// The session that the call runs in. It has the same key as the span
        /// attribute.
        static let sessionID = AttributeKey.sessionID
    }

    /// The message of the "enter" log record that ``TracedCall`` writes when a
    /// call starts.
    enum EnterRecord {
        /// The text before the span name in the message of the record.
        static let messagePrefix = "enter "

        /// Gives the message of the record of one call.
        ///
        /// - Parameter spanName: The name of the span of the call.
        /// - Returns: `enter <spanName>`.
        static func message(forSpanNamed spanName: String) -> String {
            messagePrefix + spanName
        }
    }

    /// Makes a logger with the label of the core target.
    ///
    /// Make the logger at call time, not in a stored value. A logger keeps the
    /// handler of the time that it was made.
    ///
    /// - Returns: A logger that writes through the logging backend of the
    ///   host.
    static func makeLogger() -> Logger {
        Logger(label: logLabel)
    }

    /// Makes the counter of the tool calls that have one tool name and one
    /// outcome.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Returns: The counter, with the tool name and the outcome as its
    ///   only dimensions.
    static func makeToolCallCounter(toolName: String, outcome: OperationOutcome) -> Counter {
        Counter(label: MetricName.toolCalls, dimensions: toolCallDimensions(toolName: toolName, outcome: outcome))
    }

    /// Makes the timer of the tool calls that have one tool name and one
    /// outcome.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Returns: The timer, with the tool name and the outcome as its only
    ///   dimensions.
    static func makeToolDurationTimer(toolName: String, outcome: OperationOutcome) -> Metrics.Timer {
        Metrics.Timer(
            label: MetricName.toolDuration,
            dimensions: toolCallDimensions(toolName: toolName, outcome: outcome)
        )
    }

    /// Records one tool call: one count on the counter and one duration on
    /// the timer of its tool name and outcome.
    ///
    /// The metrics are made at call time, so that they use the metrics
    /// factory that is in effect when the call ends.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    ///   - duration: The duration of the call.
    static func recordToolCall(toolName: String, outcome: OperationOutcome, duration: Duration) {
        makeToolCallCounter(toolName: toolName, outcome: outcome).increment()
        makeToolDurationTimer(toolName: toolName, outcome: outcome).record(duration: duration)
    }

    /// Gives the dimensions of a tool-call metric.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Returns: The tool name and the outcome, with the attribute keys of
    ///   the tool span as the dimension names.
    private static func toolCallDimensions(toolName: String, outcome: OperationOutcome) -> [(String, String)] {
        [
            (AttributeKey.toolName, toolName),
            (AttributeKey.outcome, outcome.rawValue),
        ]
    }
}
