import ULID

/// The format of the sender header that the session directory writes into
/// the content of a delivered message, by the rules of
/// ``SessionDirectory/send(_:)``. All header text comes from this type.
///
/// The header is one line. A blank line separates it from the text of the
/// message:
///
/// - A session sender: `From the session <title>, agent <agent> (<folder>)`.
/// - A user sender with a source session:
///   `From the user, in <title> (<folder>)`.
/// - A user sender with no source session: no header. The content is the
///   text of the message.
///
/// `<title>` is the title of the session, or its short id when it has no
/// title. `<agent>` is the display name of the agent, or the agent id when
/// the agent has no name. `<folder>` is the path of the working folder. When
/// the directory does not know the session, the header names only the
/// session id: `From the session <id>`, or `From the user, in the session
/// <id>`.
enum SessionSenderHeader {
    /// The text between the header line and the text of the message.
    private static let separator = "\n\n"

    /// The session that the header of `message` names: the sender session
    /// for a session sender, or the source session for a user sender.
    ///
    /// - Parameter message: A delivered message.
    /// - Returns: The session id, or `nil` for a user sender with no source
    ///   session.
    static func namedSession(of message: SessionMessage) -> ULID? {
        switch message.from {
        case .session(let sender): sender
        case .user: message.sourceSession
        }
    }

    /// The content of the mail that carries `message`: the header line, a
    /// blank line and the text, or only the text when the message gets no
    /// header.
    ///
    /// - Parameters:
    ///   - message: A delivered message.
    ///   - summary: The summary of the session that ``namedSession(of:)``
    ///     gives, or `nil` when the directory does not know that session.
    /// - Returns: The content of the mail.
    static func content(of message: SessionMessage, summary: SessionSummary?) -> String {
        guard let line = line(of: message, summary: summary) else { return message.text }
        return line + separator + message.text
    }

    /// The header line of `message`.
    ///
    /// - Parameters:
    ///   - message: A delivered message.
    ///   - summary: The summary of the named session, or `nil`.
    /// - Returns: The header line, or `nil` for a user sender with no source
    ///   session.
    private static func line(of message: SessionMessage, summary: SessionSummary?) -> String? {
        guard let id = namedSession(of: message) else { return nil }
        switch message.from {
        case .session:
            guard let summary else { return "From the session \(id.ulidString)" }
            return "From the session \(name(of: summary)), agent \(agent(of: summary)) (\(folder(of: summary)))"
        case .user:
            guard let summary else { return "From the user, in the session \(id.ulidString)" }
            return "From the user, in \(name(of: summary)) (\(folder(of: summary)))"
        }
    }

    /// The title of the session, or its short id when the title is missing
    /// or empty.
    ///
    /// - Parameter summary: The summary of the session.
    /// - Returns: The name that the header shows.
    private static func name(of summary: SessionSummary) -> String {
        guard let title = summary.title, !title.isEmpty else { return summary.shortID }
        return title
    }

    /// The display name of the agent, or the agent id when the agent has no
    /// name.
    ///
    /// - Parameter summary: The summary of the session.
    /// - Returns: The agent that the header shows.
    private static func agent(of summary: SessionSummary) -> String {
        summary.agentName ?? summary.agentID
    }

    /// The path of the working folder of the session.
    ///
    /// - Parameter summary: The summary of the session.
    /// - Returns: The folder that the header shows.
    private static func folder(of summary: SessionSummary) -> String {
        summary.workingDirectory.path
    }
}
