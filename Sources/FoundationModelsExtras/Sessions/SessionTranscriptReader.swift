import Foundation
import ULID

/// Gives the recorded events of a session. The host makes one and gives it
/// when it makes the ``MountSite`` or the ``ToolContext`` of a session. A tool
/// reads through ``ToolContext/transcript(of:)``.
///
/// The host decides which sessions it can give. Extras applies no rule about
/// the tree of sessions, and it checks no session id: a reader can give any
/// session that it knows, also a session that is not the session of the call.
///
/// A reader gives only what the host has on disk. It does not flush. A
/// running session can lack its latest events, so a caller must not read the
/// transcript of a running session as complete.
public protocol SessionTranscriptReader: Sendable {
    /// Gives the transcript of a session.
    ///
    /// - Parameter sessionID: The session to read.
    /// - Returns: The recorded events of the session that the host has on
    ///   disk.
    /// - Throws: ``SessionTranscriptError/notFound(_:)`` when the host does
    ///   not know `sessionID`.
    func transcript(of sessionID: ULID) async throws -> SessionTranscript
}
