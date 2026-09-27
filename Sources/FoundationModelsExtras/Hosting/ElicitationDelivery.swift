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
