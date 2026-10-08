import Foundation
import FoundationModels

/// Marks a `Tool` as a background tool.
///
/// A call of a tool with a background ``mount`` waits for its run up to
/// ``inlineSettleGrace``. A run that ends in that time answers with its own
/// result. A run that continues answers with a ``PendingRunEnvelope``, and
/// the work continues behind it. A `Tool` that
/// does not conform runs to completion. A tool can also choose the mount of
/// each call with ``mount(for:)``. Each requirement has a default, so a tool
/// declares only what it needs.
///
/// The result of a background run is a short report, not the output. The
/// output stays in the tool. The report tells what ran, how it ended, and
/// how to get the output. The host gives the report to the model unchanged.
public protocol BackgroundTool {
    /// The mount that this tool needs, or `nil` to use the mount of the
    /// host. A declared mount wins over the host, the timeout also.
    var mount: ToolMount? { get }

    /// The mount of one call, read from its arguments. The host asks for it
    /// before the call runs. A synchronous call answers with its output, and
    /// a background call answers with a ``PendingRunEnvelope``.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The mount of the call, or `nil` to use the mount of the host.
    func mount(for arguments: GeneratedContent) -> ToolMount?

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

    /// How long a call waits for its own run before it answers, in seconds.
    ///
    /// A run that ends in this time answers with its own result, the same as
    /// a synchronous call: the output of the tool, or the error that it
    /// threw. Only a run that continues answers with a ``PendingRunEnvelope``.
    /// `0` answers with the envelope at once.
    ///
    /// The default reads the settle period that the host configured on the
    /// mount site, and that is ``ToolMount/defaultInlineSettleGrace`` when
    /// the host configured none. State a value only when this tool needs a
    /// value different from the host.
    ///
    /// The default reads the configured value only while the runner reads
    /// it. Read anywhere else, for example in the body of the tool, it gives
    /// ``ToolMount/defaultInlineSettleGrace``. A running tool reads the value
    /// of its session from ``ToolContext/inlineSettleGrace`` of
    /// ``ToolContext/current``.
    var inlineSettleGrace: TimeInterval { get }

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

    /// The default: no declared mount.
    public var mount: ToolMount? { nil }

    /// The default: ``mount``, the same for each call.
    public func mount(for arguments: GeneratedContent) -> ToolMount? {
        mount
    }

    /// The default: the settle period that the host configured.
    public var inlineSettleGrace: TimeInterval {
        InlineSettle.configuredGrace
    }

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

/// The settle period that the host configured, as the default
/// ``BackgroundTool/inlineSettleGrace`` reads it.
///
/// ``BackgroundToolRunner`` binds the value of its mount site around the read
/// of the grace of a tool. A read outside that binding gets
/// ``ToolMount/defaultInlineSettleGrace``.
enum InlineSettle {
    /// The settle period of the current mount site, in seconds.
    @TaskLocal static var configuredGrace: TimeInterval = ToolMount.defaultInlineSettleGrace
}
