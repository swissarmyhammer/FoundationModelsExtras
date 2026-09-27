import ULID

/// The records that one tool call attached.
///
/// The report has the same identity as the ``ToolInvocationRecord`` of the
/// call, so a host can join the two. A host decodes each attachment by its
/// ``ToolCallAttachment/schemaName``.
public struct ToolCallReport: Sendable, Equatable {
    /// The tool name that the session shows. The record of the call has the
    /// same name.
    public let tool: String

    /// The operation that the call ran.
    public let op: String

    /// The completion token of the run. It is the same value as
    /// ``ToolInvocationRecord/correlationID``, not a `Transcript.ToolCall.id`.
    public let correlationID: String

    /// The session that the call ran in.
    public let sessionID: ULID

    /// The records that the call attached, in call order. At least one.
    public let attachments: [ToolCallAttachment]

    /// Makes a report for one call.
    ///
    /// - Parameters:
    ///   - tool: The tool name that the session shows.
    ///   - op: The operation that the call ran.
    ///   - correlationID: The completion token of the run.
    ///   - sessionID: The session that the call ran in.
    ///   - attachments: The records that the call attached, in call order.
    public init(tool: String, op: String, correlationID: String, sessionID: ULID, attachments: [ToolCallAttachment]) {
        self.tool = tool
        self.op = op
        self.correlationID = correlationID
        self.sessionID = sessionID
        self.attachments = attachments
    }

    /// Makes the report of one closed call, or `nil` when the call attached
    /// nothing.
    ///
    /// - Parameters:
    ///   - record: The close record of the call.
    ///   - attachments: The records that the call attached, in call order.
    init?(closing record: ToolInvocationRecord, attachments: [ToolCallAttachment]) {
        guard !attachments.isEmpty else { return nil }
        self.init(
            tool: record.tool,
            op: record.op,
            correlationID: record.correlationID,
            sessionID: record.sessionID,
            attachments: attachments
        )
    }
}
