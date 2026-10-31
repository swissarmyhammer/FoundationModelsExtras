import ULID

/// The result of one send for one target session. A send gives one receipt
/// for each target.
public struct SessionSendReceipt: Sendable, Codable, Equatable {
    /// What happened to the message at one target.
    public enum Outcome: String, Sendable, Codable {
        /// The target was idle: the message starts a turn.
        case delivered

        /// The target works: the message waits for the turn end.
        case queued

        /// An agent address started a new root session.
        case started

        /// A loop guard, an archived target or no match refused the message.
        case refused

        /// The message is written where the target reads it, but it is not in
        /// the queue of the target yet. The send does not tell if the target
        /// starts a turn. A later delivery event tells that.
        case sent
    }

    /// The id of the mail that carries the message, or `nil` when no mail
    /// was made.
    public let messageID: MailID?

    /// The target session, or `nil` when no session matched the address.
    public let target: ULID?

    /// What happened to the message.
    public let outcome: Outcome

    /// Why the message was refused, or `nil` when it was not.
    public let reason: String?

    /// Makes a receipt.
    ///
    /// - Parameters:
    ///   - messageID: The id of the mail that carries the message. The
    ///     default is `nil`.
    ///   - target: The target session. The default is `nil`.
    ///   - outcome: What happened to the message.
    ///   - reason: Why the message was refused. The default is `nil`.
    public init(messageID: MailID? = nil, target: ULID? = nil, outcome: Outcome, reason: String? = nil) {
        self.messageID = messageID
        self.target = target
        self.outcome = outcome
        self.reason = reason
    }
}
