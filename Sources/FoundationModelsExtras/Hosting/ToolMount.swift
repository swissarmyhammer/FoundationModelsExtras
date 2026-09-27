import Foundation

/// The mode and the timeout that a tool is mounted with.
public struct ToolMount: Sendable, Equatable {
    /// How a call runs.
    public enum Mode: Sendable, Equatable {
        /// A call answers at once with a pending envelope. The work
        /// continues behind it.
        case background

        /// A call runs to completion.
        case runToCompletion
    }

    /// Run to completion, with no timeout.
    public static let synchronous = ToolMount(mode: .runToCompletion)

    /// How a call runs.
    public var mode: Mode

    /// How long the work can run with no progress, in seconds, or `nil` for
    /// no timeout. Each progress event starts the time again, and a pending
    /// elicitation stops it. When the time elapses, the run ends as
    /// ``OperationOutcome/timedOut``.
    public var timeout: TimeInterval?

    /// Makes a mount.
    ///
    /// - Parameters:
    ///   - mode: How a call runs.
    ///   - timeout: The timeout in seconds, or `nil` for no timeout.
    public init(mode: Mode, timeout: TimeInterval? = nil) {
        self.mode = mode
        self.timeout = timeout
    }
}

/// The failure that a mount makes. The model reads it in place of the
/// output of the tool.
public enum ToolMountError: Error, Equatable, CustomStringConvertible {
    /// The timeout elapsed with no progress and no pending elicitation.
    case timedOut(tool: String, timeoutSeconds: TimeInterval)

    /// The text that the model reads.
    public var description: String {
        switch self {
        case .timedOut(let tool, let timeoutSeconds):
            "\(tool) timed out after \(timeoutSeconds) seconds with no progress"
        }
    }
}
