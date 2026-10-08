/// The category of a posted `OperationEvent`.
///
/// Only `.completed` is terminal. A run that posts any event must post
/// exactly one `.completed` event before it ends. A run that settles
/// in-band with no events may post nothing.
public enum OperationEventKind: String, Codable, Sendable, Equatable {
    /// The operation is still running; `OperationEvent.detail` describes its progress.
    /// `OperationEvent.plan` can carry the agent plan for the host.
    case progress

    /// The operation has finished; `OperationEvent.outcome` states how it ended.
    case completed

    /// The operation asks the user for input; `OperationEvent.elicitation` carries the request.
    /// Never terminal.
    case elicitation

    /// The operation sends mail to the session that called it, while the
    /// operation continues. `OperationEvent.detail` holds the text of the
    /// message, and `OperationEvent.outcome` is `nil`. Never terminal. The
    /// session that gets the event can start an answer for it. A message that
    /// a run posts after its terminal event is dropped.
    case message
}

/// A progress, completion, elicitation, or message event a long-running operation
/// posts through a connected `OperationEventSink`.
/// See `OperationEventKind` for the terminal-event contract.
public struct OperationEvent: Codable, Sendable, Equatable {
    /// The name of the fused tool (`OperationTool.name`) that posted this event.
    public let tool: String

    /// The canonical `"verb noun"` op string of the operation that posted this event.
    public let op: String

    /// A tool-assigned identifier that correlates every event from the same run.
    /// Opaque to this package.
    public let correlationID: String

    /// Whether this event reports progress, completion, a request for user input,
    /// or a message to the calling session.
    public let kind: OperationEventKind

    /// A JSON-string payload in a shape the emitting tool owns. Opaque to this package.
    public let detail: String

    /// How the operation run ended. Non-nil if and only if `kind == .completed`.
    /// Decoded with `decodeIfPresent`, so older recorded events decode unchanged.
    public let outcome: OperationOutcome?

    /// The typed request for user input. Non-nil if and only if `kind == .elicitation`.
    /// Decoded with `decodeIfPresent`, so older recorded events decode unchanged.
    public let elicitation: ElicitationRequest?

    /// The agent plan that goes to the host. Non-nil only when `kind == .progress`.
    /// The model never gets it: `detail` holds the text for the model.
    /// Decoded with `decodeIfPresent`, so older recorded events decode unchanged.
    public let plan: PlanSnapshot?

    /// Creates an event with the given fields.
    /// - Parameters:
    ///   - tool: The name of the posting tool.
    ///   - op: The `"verb noun"` op string of the posting operation.
    ///   - correlationID: The identifier of the operation run.
    ///   - kind: The event category.
    ///   - detail: The tool-owned JSON-string payload.
    ///   - outcome: How the run ended; non-nil only when `kind == .completed`.
    ///   - elicitation: The request for user input; non-nil only when `kind == .elicitation`.
    ///   - plan: The agent plan for the host; non-nil only when `kind == .progress`.
    public init(
        tool: String,
        op: String,
        correlationID: String,
        kind: OperationEventKind,
        detail: String,
        outcome: OperationOutcome? = nil,
        elicitation: ElicitationRequest? = nil,
        plan: PlanSnapshot? = nil
    ) {
        self.tool = tool
        self.op = op
        self.correlationID = correlationID
        self.kind = kind
        self.detail = detail
        self.outcome = outcome
        self.elicitation = elicitation
        self.plan = plan
    }
}
