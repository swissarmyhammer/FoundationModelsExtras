import ULID

/// The content of one ``Mail``.
///
/// This is a closed set. The session has one rule for each case: how to
/// write it to the transcript, how to read it at restore, if it starts an
/// answer, if it shares a submission, and how to render it into the
/// context. Add a case only for a new meaning. Put new data in the payloads.
public enum MailBody: Sendable, Codable, Equatable {
    /// A message from the user, with its generation options.
    case userMessage(prompt: String, options: UserMessageOptions)

    /// An event of a tool run: a result, a progress report or a message.
    case runEvent(OperationEvent)

    /// The answer to an elicitation. The session takes it as one more post
    /// from the user.
    case elicitationAnswer(id: ULID, response: ElicitationResponse)

    /// A message from an other session. `from` is the session id of the
    /// sender.
    case agentMessage(from: ULID, content: String)

    /// The kind of this body.
    public var kind: MailKind {
        switch self {
        case .userMessage: .userMessage
        case .runEvent: .runEvent
        case .elicitationAnswer: .elicitationAnswer
        case .agentMessage: .agentMessage
        }
    }
}

/// The kind of one ``MailBody``, with no payload.
///
/// Router uses the raw value as the telemetry dimension `mail.kind`. Thus
/// the raw values are stable API: do not change them.
public enum MailKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// A ``MailBody/userMessage(prompt:options:)``.
    case userMessage = "user_message"

    /// A ``MailBody/runEvent(_:)``.
    case runEvent = "run_event"

    /// A ``MailBody/elicitationAnswer(id:response:)``.
    case elicitationAnswer = "elicitation_answer"

    /// A ``MailBody/agentMessage(from:content:)``.
    case agentMessage = "agent_message"
}
