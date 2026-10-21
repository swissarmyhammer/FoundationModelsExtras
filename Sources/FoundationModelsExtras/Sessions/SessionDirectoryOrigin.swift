/// How a root session started. The `sessions` graph uses it for the tab
/// rule.
///
/// The name is not `SessionOrigin`, because FoundationModelsHooks already
/// has a public `SessionOrigin`, and Router uses both modules.
public enum SessionDirectoryOrigin: String, Sendable, Codable {
    /// `session/new`, or the `start` mutation of a UI.
    case client

    /// `start session` of the `sessions` tool.
    case tool

    /// A message to an agent with no live root session.
    case message

    /// A kanban column trigger (D60).
    case trigger

    /// A user forked another session.
    case fork
}
