import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// Values and a JSON round trip that the tests of the session directory
/// types share.
enum SessionFixtures {
    /// The seconds from the reference date to ``createdAt``.
    private static let createdSeconds: TimeInterval = 800_000_000

    /// The seconds from ``createdAt`` to ``updatedAt``: ten minutes.
    private static let workSeconds: TimeInterval = 600

    /// A fixed creation time, thus a round trip compares an exact value.
    static let createdAt = Date(timeIntervalSinceReferenceDate: createdSeconds)

    /// A fixed update time, later than ``createdAt``.
    static let updatedAt = createdAt.addingTimeInterval(workSeconds)

    /// The working folder of the sample sessions.
    static let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    /// The chain depth of a message that a session sent from a user turn.
    static let secondLinkDepth = 2

    /// Encodes `value` as JSON and decodes it again.
    ///
    /// - Parameter value: The value to send through JSON.
    /// - Returns: The decoded value.
    static func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    /// Encodes `value` as JSON, removes one top-level key, and decodes the
    /// result. The JSON is the same as the JSON of a version that did not
    /// have the field of that key. The encoded JSON must hold the key, thus
    /// the value must set that field.
    ///
    /// - Parameters:
    ///   - key: The top-level key to remove.
    ///   - value: The value to send through JSON.
    /// - Returns: The value decoded from the JSON with no `key`.
    static func decodeWithout<Value: Codable>(key: String, from value: Value) throws -> Value {
        let encoded = try JSONEncoder().encode(value)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        try #require(object.removeValue(forKey: key) != nil)
        let reduced = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Value.self, from: reduced)
    }

    /// A summary that sets every field, the optional ones too.
    ///
    /// - Parameter id: The session id. The default is a new id.
    /// - Returns: The summary.
    static func summary(id: ULID = ULID()) -> SessionSummary {
        SessionSummary(
            id: id,
            agentID: "default",
            agentName: "Default agent",
            workingDirectory: folder,
            title: "Fix the build",
            tags: ["build", "urgent"],
            kind: .fork,
            state: .needsInput,
            parentID: ULID(),
            startedBy: ULID(),
            origin: .fork,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastSummary: "The build is green.",
            isLive: true,
            pinnedAt: createdAt,
            lastUsedAt: updatedAt)
    }

    /// A message from a session that replies to an other message.
    static func message() -> SessionMessage {
        SessionMessage(
            id: MailID(),
            from: .session(ULID()),
            to: ULID(),
            text: "The tests pass now.",
            inReplyTo: MailID(),
            sentAt: createdAt,
            chainDepth: secondLinkDepth,
            isRead: false)
    }
}
