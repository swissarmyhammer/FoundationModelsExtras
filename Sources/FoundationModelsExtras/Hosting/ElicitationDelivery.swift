import ULID

/// One question that waits for the user, and the run that asked it.
///
/// The question stops the run of ``runToken`` until the user answers. For a
/// synchronous call that a run mounted, ``runToken`` names the run that holds
/// the call, not the call itself.
public struct OpenElicitation: Sendable, Equatable {
    /// The id of the elicitation. An answer addresses it.
    public let elicitationId: ULID

    /// The completion token of the run that asked the question.
    public let runToken: String
}

/// What the host session did with the answer to an elicitation.
public enum ElicitationAnswerDelivery: Sendable, Equatable {
    /// The answer resumed the waiting run and closed the elicitation.
    case delivered

    /// A URL-mode accept was recorded. The run resumes when the completion
    /// of the elicitation arrives.
    case acceptedAwaitingCompletion

    /// No pending elicitation has the id. Nothing occurs.
    case noPendingElicitation
}

/// What the host session did with the completion of a URL-mode elicitation.
public enum ElicitationCompletionDelivery: Sendable, Equatable {
    /// The completion resumed the accepted elicitation and closed it.
    case completed

    /// No accepted pending elicitation has the id. Nothing occurs.
    case noPendingElicitation
}
