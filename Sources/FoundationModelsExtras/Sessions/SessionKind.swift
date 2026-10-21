/// The kind of a session.
public enum SessionKind: String, Sendable, Codable, CaseIterable {
    /// A client started it, or another session, a message or a trigger
    /// started it.
    case root

    /// The `agents` tool started it. It works in the folder of its parent.
    case subagent

    /// A user forked another session.
    case fork
}
