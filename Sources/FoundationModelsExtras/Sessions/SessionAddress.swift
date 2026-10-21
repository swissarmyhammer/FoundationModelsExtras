import Foundation
import ULID

/// A target of a message.
public enum SessionAddress: Sendable, Codable, Hashable {
    /// One session, by its id.
    case session(ULID)

    /// The newest live root session of the agent, in `folder` when it is
    /// given, else in the folder of the sender. If there is none, the
    /// directory starts one (origin ``SessionDirectoryOrigin/message``).
    case agent(id: String, folder: URL?)

    /// The newest live root session with this working folder, of any agent.
    /// If there is none, the send is refused. A folder alone does not name
    /// an agent (D61).
    case folder(URL)

    /// Each live session that has the tag, but not the sender.
    case tag(String)
}
