import Foundation
import ULID

/// One recorded event of a session, in a form that does not depend on the
/// event types of the host.
///
/// The host maps each event that it recorded into one entry.
public struct SessionTranscriptEntry: Sendable, Codable, Equatable {
    /// The kind of the event, as a name that the host chooses, for example
    /// `"prompt"` or `"toolCall"`.
    public var kind: String

    /// The time that the host recorded the event.
    public var timestamp: Date

    /// The content of the event, as a JSON value. It is usually an
    /// ``OperationValue/object(_:)``.
    public var payload: OperationValue

    /// Makes an entry.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event.
    ///   - timestamp: The time that the host recorded the event.
    ///   - payload: The content of the event.
    public init(kind: String, timestamp: Date, payload: OperationValue) {
        self.kind = kind
        self.timestamp = timestamp
        self.payload = payload
    }
}

/// The recorded events of one session, in the order that the host recorded
/// them.
public struct SessionTranscript: Sendable, Codable, Equatable {
    /// The session that the entries belong to.
    public var sessionID: ULID

    /// The entries, oldest first.
    public var entries: [SessionTranscriptEntry]

    /// Makes a transcript.
    ///
    /// - Parameters:
    ///   - sessionID: The session that the entries belong to.
    ///   - entries: The entries, oldest first.
    public init(sessionID: ULID, entries: [SessionTranscriptEntry]) {
        self.sessionID = sessionID
        self.entries = entries
    }
}
