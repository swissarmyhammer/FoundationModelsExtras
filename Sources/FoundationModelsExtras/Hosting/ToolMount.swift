import Foundation

/// The mode and the timeout that a tool is mounted with.
public struct ToolMount: Sendable, Equatable {
    /// How a call runs.
    public enum Mode: Sendable, Equatable {
        /// A call waits for its run up to the settle period. A run that
        /// ends in that time answers with its own result. A run that
        /// continues answers with a pending envelope, and the work
        /// continues behind it.
        case background

        /// A call runs to completion.
        case runToCompletion
    }

    /// Run to completion, with no timeout.
    public static let synchronous = ToolMount(mode: .runToCompletion)

    /// The default settle period of a background call, in seconds: 6.
    ///
    /// A background call waits this long for its own run. A run that ends in
    /// this time answers with its own result, the same as a synchronous call.
    /// Only a run that continues answers with a ``PendingRunEnvelope``.
    ///
    /// This is the only place that states the number. A host changes the
    /// value through ``MountSite/init(sessionID:runPlane:sink:op:tracer:inlineSettleGrace:)``,
    /// and a tool can state its own value through
    /// ``BackgroundTool/inlineSettleGrace``.
    public static let defaultInlineSettleGrace: TimeInterval = 6

    /// How a call runs.
    public var mode: Mode

    /// How long the work can run with no progress, in seconds, or `nil` for
    /// no timeout. Each progress event, each message and each display event
    /// starts the time again, and a pending elicitation stops it. When the
    /// time elapses, the run ends as ``OperationOutcome/timedOut``.
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
