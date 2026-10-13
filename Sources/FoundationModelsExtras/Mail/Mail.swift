/// One input message to a session.
///
/// All input to a session is mail: user messages, tool and run results,
/// elicitation answers, and messages from other sessions. Mail waits in
/// the mail queue of the session until the session takes it. The output
/// events that the mail causes carry its ``id``.
public struct Mail: Sendable, Codable, Equatable {
    /// The correlation id of the mail.
    public let id: MailID

    /// The party that sent the mail.
    public let sender: MailSender

    /// The content of the mail.
    public let body: MailBody

    /// Makes a mail.
    ///
    /// The caller can give the id, for example the `messageId` of an ACP
    /// prompt. If it does not, the mail gets a new id. A session refuses a
    /// mail whose id it already has: ``MailSink/mail(_:)`` throws
    /// ``MailRefusal/duplicateID(_:)``.
    ///
    /// - Parameters:
    ///   - id: The correlation id. The default is a new id.
    ///   - sender: The party that sends the mail.
    ///   - body: The content of the mail.
    public init(id: MailID = MailID(), sender: MailSender, body: MailBody) {
        self.id = id
        self.sender = sender
        self.body = body
    }
}
