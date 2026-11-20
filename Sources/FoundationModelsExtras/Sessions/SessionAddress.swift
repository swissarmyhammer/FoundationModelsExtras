import Foundation
import ULID

/// A target of a message.
///
/// A message goes to one session, to a new session of an agent, or to the
/// sessions that have a tag. A folder is not a target.
public enum SessionAddress: Sendable, Codable, Hashable {
    /// One session, by its id.
    case session(ULID)

    /// A new root session of the agent. The directory starts the session
    /// (origin ``SessionDirectoryOrigin/message``). `folder` is the folder in
    /// which the new session starts. When it is `nil`, the session starts in
    /// the folder of the sender.
    case agent(id: String, folder: URL?)

    /// Each live session that has the tag, but not the sender.
    case tag(String)
}
