import Logging
import Metrics

/// The telemetry names of the core target, and the logger and the tool-call
/// metrics that use them.
///
/// Each name starts with the module name. The core target uses the swift-log
/// and swift-metrics APIs only, and it bootstraps no backend. The executables
/// of the family bootstrap the backend. Until one does, each logger and each
/// metric does nothing.
///
/// A metric dimension carries the tool name and the outcome only. It never
/// carries tool arguments or tool output, because a dimension leaves the
/// process through the metrics backend of the host.
enum ExtrasTelemetry {
    /// The label of each logger of the core target.
    static let logLabel = "FoundationModelsExtras"

    /// The metric names of the core target.
    enum MetricName {
        /// The counter that counts each tool call.
        static let toolCalls = "FoundationModelsExtras.tool.calls"

        /// The timer that records the duration of each tool call.
        static let toolDuration = "FoundationModelsExtras.tool.duration"
    }

    /// Makes a logger with the label of the core target.
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

    /// Gives the dimensions of a tool-call metric.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Returns: The tool name and the outcome, with the attribute keys of
    ///   the tool span as the dimension names.
    private static func toolCallDimensions(toolName: String, outcome: OperationOutcome) -> [(String, String)] {
        [
            (ToolCallSpan.AttributeKey.toolName, toolName),
            (ToolCallSpan.AttributeKey.outcome, outcome.rawValue),
        ]
    }
}
