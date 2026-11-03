import Foundation
import ULID

/// The errors that a read of a session transcript throws.
public enum SessionTranscriptError: Error, Sendable, Codable, Equatable {
    /// The reader of the host does not know this session id. The host decides
    /// which ids it can give, so the id can be unknown, or it can be an id
    /// that the host does not share.
    case notFound(ULID)

    /// The host gave no ``SessionTranscriptReader``, so there is no
    /// transcript source.
    case noSource
}
