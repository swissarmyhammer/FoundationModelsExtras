extension InMemorySessionDirectory {
    /// The mail that carries a message, by the body-choice rule of
    /// ``SessionDirectory/send(_:)``: a session sender gives
    /// ``MailBody/agentMessage(from:content:)`` with the sender
    /// ``MailSender/session(_:)``, and a UI sender gives
    /// ``MailBody/userMessage(prompt:options:)`` with the sender
    /// ``MailSender/user``.
    ///
    /// The content starts with the sender header of the directory, by the
    /// header rule of ``SessionDirectory/send(_:)``. A session sender gets a
    /// header with its title, its agent and its folder. A user sender with a
    /// source session gets a header that names the source session. A user
    /// sender with no source session gets no header. The header uses the
    /// summary that the directory holds now. When the directory does not know
    /// the named session, the header names only the session id.
    ///
    /// The test double keeps no mail queue. A test of a consumer reads the
    /// mail of a delivered message with this function.
    ///
    /// - Parameter message: A delivered message.
    /// - Returns: The mail that carries it, with the id of the message.
    public func mail(carrying message: SessionMessage) -> Mail {
        let summary = SessionSenderHeader.namedSession(of: message).flatMap { id in
            state.withLock { $0.entries[id]?.summary }
        }
        let content = SessionSenderHeader.content(of: message, summary: summary)
        switch message.from {
        case .session(let sender):
            return Mail(id: message.id, sender: .session(sender), body: .agentMessage(from: sender, content: content))
        case .user:
            return Mail(
                id: message.id, sender: .user, body: .userMessage(prompt: content, options: UserMessageOptions()))
        }
    }
}
