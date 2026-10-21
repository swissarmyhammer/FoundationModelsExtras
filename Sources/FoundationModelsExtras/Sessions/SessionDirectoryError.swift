import Foundation
import ULID

/// The errors that the directory throws. The `sessions` tool turns each one
/// into a corrective text. The `sessions` graph turns each one into a
/// GraphQL error.
public enum SessionDirectoryError: Error, Sendable, Codable, Equatable {
    /// No session has this id.
    case unknownSession(ULID)

    /// No agent has this id. `nearNames` are the ids of the agents with a
    /// near name, for the corrective.
    case unknownAgent(String, nearNames: [String])

    /// The working folder is not a folder.
    case notADirectory(URL)

    /// The message is deeper in its chain than the loop guard allows.
    case chainTooDeep(limit: Int)

    /// The text of the message is longer than the limit.
    case messageTooLong(limit: Int)

    /// The tag is not a valid tag.
    case invalidTag(String)

    /// The directory has no launcher, thus it cannot start a session.
    case noLauncher
}
