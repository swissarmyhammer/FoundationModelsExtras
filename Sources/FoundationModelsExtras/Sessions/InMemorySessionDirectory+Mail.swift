extension InMemorySessionDirectory {
    /// The mail that carries a message, by the body-choice rule of
    /// ``SessionDirectory/send(_:)``: a session sender gives
    /// ``MailBody/agentMessage(from:content:)`` with the sender
    /// ``MailSender/session(_:)``, and a UI sender gives
    /// ``MailBody/userMessage(prompt:options:)`` with the sender
    /// ``MailSender/user``.
    ///
    /// The test double keeps no mail queue, and it renders no sender header:
    /// the content is the text of the message. A test of a consumer reads the
    /// mail of a delivered message with this function.
    ///
    /// - Parameter message: A delivered message.
    /// - Returns: The mail that carries it, with the id of the message.
    public static func mail(carrying message: SessionMessage) -> Mail {
        switch message.from {
        case .session(let sender):
            Mail(id: message.id, sender: .session(sender), body: .agentMessage(from: sender, content: message.text))
        case .user:
            Mail(id: message.id, sender: .user, body: .userMessage(prompt: message.text, options: UserMessageOptions()))
        }
    }
}
