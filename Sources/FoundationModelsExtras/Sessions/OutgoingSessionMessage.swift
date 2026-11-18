import ULID

/// A message to send with ``SessionDirectory/send(_:)``.
public struct OutgoingSessionMessage: Sendable, Codable, Equatable {
    /// The session or the user that sends the message.
    public var from: SessionMessageSender

    /// The target of the message.
    public var to: SessionAddress

    /// The text of the message.
    public var text: String

    /// The id of the message that this message answers, or `nil` for a
    /// message that answers none.
    public var inReplyTo: MailID?

    /// The session in which the user wrote the message, or `nil` when the
    /// user wrote it in no session. Only a user sender
    /// (``SessionMessageSender/user(clientID:)``) uses this field. JSON with
    /// no `sourceSession` key decodes as `nil`.
    public var sourceSession: ULID?

    /// Makes a message to send.
    ///
    /// - Parameters:
    ///   - from: The session or the user that sends the message.
    ///   - to: The target of the message.
    ///   - text: The text of the message.
    ///   - inReplyTo: The id of the message that this message answers. The
    ///     default is `nil`.
    ///   - sourceSession: The session in which the user wrote the message.
    ///     Only a user sender uses it. The default is `nil`.
    public init(
        from: SessionMessageSender,
        to: SessionAddress,
        text: String,
        inReplyTo: MailID? = nil,
        sourceSession: ULID? = nil
    ) {
        self.from = from
        self.to = to
        self.text = text
        self.inReplyTo = inReplyTo
        self.sourceSession = sourceSession
    }
}
