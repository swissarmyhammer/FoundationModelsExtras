import Foundation
import FoundationModels

/// Marks a `Tool` as a background tool.
///
/// A call of a tool with a background ``mount`` answers at once with a
/// ``PendingRunEnvelope``, and the work continues behind it. A `Tool` that
/// does not conform runs to completion. Each requirement has a default, so a
/// tool declares only what it needs.
///
/// The result of a background run is a short report, not the output. The
/// output stays in the tool. The report tells what ran, how it ended, and
/// how to get the output. The host gives the report to the model unchanged.
public protocol BackgroundTool {
    /// The mount that this tool needs, or `nil` to use the mount of the
    /// host. A declared mount wins over the host, the timeout also.
    var mount: ToolMount? { get }

    /// The timeout of one call, read from its arguments.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The timeout in seconds, or `nil` to use the mount's timeout.
    func timeout(from arguments: GeneratedContent) -> TimeInterval?

    /// The `next` sentence of a pending envelope. It must name
    /// `completionToken`.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The sentence as plain text. The envelope escapes it.
    func collectInstruction(forCompletionToken completionToken: String) -> String

    /// How long a call waits for its own run before it answers, or `nil` to
    /// answer at once.
    ///
    /// A run that ends in this time answers with a settled envelope, which
    /// holds the result. Thus the model does not call `wait`. Keep the value
    /// small: the model waits for this time on each call.
    var inlineSettleGrace: TimeInterval? { get }

    /// The `next` sentence of a settled envelope. It must tell the model to
    /// answer from the `detail` field, and that there is nothing to collect.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The sentence as plain text. The envelope escapes it.
    func resultInstruction(forCompletionToken completionToken: String) -> String

    /// The kind of work of a background call. A ``RunKind/process`` tool must
    /// give ``canceler(forCompletionToken:)``.
    var runKind: RunKind { get }

    /// The canceler of the run with `completionToken`.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The canceler, or `nil` to use the cooperative canceler,
    ///   which reports ``OperationOutcome/cancelled``.
    func canceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)?
}

extension BackgroundTool {
    /// The default: ``PendingRunEnvelope/defaultCollectInstruction(forCompletionToken:)``.
    public func collectInstruction(forCompletionToken completionToken: String) -> String {
        PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// The default: ``PendingRunEnvelope/defaultResultInstruction(forCompletionToken:)``.
    public func resultInstruction(forCompletionToken completionToken: String) -> String {
        PendingRunEnvelope.defaultResultInstruction(forCompletionToken: completionToken)
    }

    /// The default: no declared mount.
    public var mount: ToolMount? { nil }

    /// The default: no wait, so a call answers at once.
    public var inlineSettleGrace: TimeInterval? { nil }

    /// The default: no timeout for one call.
    public func timeout(from arguments: GeneratedContent) -> TimeInterval? {
        nil
    }

    /// The default: ``RunKind/swiftTask``.
    public var runKind: RunKind { .swiftTask }

    /// The default: `nil`, so the cooperative canceler is used.
    public func canceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)? {
        nil
    }
}
