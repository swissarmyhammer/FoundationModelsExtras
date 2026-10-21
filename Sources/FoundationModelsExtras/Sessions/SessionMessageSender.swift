import ULID

/// Who sends a message.
public enum SessionMessageSender: Sendable, Codable, Hashable {
    /// A session (the `sessions` tool). The value is the session id.
    case session(ULID)

    /// A person through a UI (the `sessions` graph). The client id is for
    /// the audit.
    case user(clientID: String)
}
