/// The work state of a session.
public enum SessionState: String, Sendable, Codable, CaseIterable {
    /// The session runs a turn.
    case working

    /// The session waits for an answer: an elicitation or a permission
    /// request.
    case needsInput

    /// The session runs no turn and waits for no answer. A message to it
    /// starts a turn.
    case idle

    /// Session > Archive or `archive session` ended the session (D68, D72).
    /// Its transcript stays on disk. It takes no message.
    case archived
}
