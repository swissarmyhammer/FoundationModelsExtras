import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``OutgoingSessionMessage`` is a message to send, and ``SessionMessage`` is a
/// message that the directory delivered.
@Suite("Session messages: the message to send and the delivered message")
struct SessionMessageTests {
    @Test("a reply from a session to a tag survives a JSON round trip")
    func aReplySurvivesARoundTrip() throws {
        let message = OutgoingSessionMessage(
            from: .session(ULID()), to: .tag("build"), text: "Done.", inReplyTo: MailID())

        #expect(try SessionFixtures.roundTrip(message) == message)
    }

    @Test("a first message from a user has no reply id and survives a JSON round trip")
    func aFirstMessageSurvivesARoundTrip() throws {
        let message = OutgoingSessionMessage(
            from: .user(clientID: "testudo-window-1"),
            to: .agent(id: "reviewer", folder: nil),
            text: "Please review the change.")

        let decoded = try SessionFixtures.roundTrip(message)

        #expect(decoded == message)
        #expect(decoded.inReplyTo == nil)
    }

    @Test("a delivered message survives a JSON round trip")
    func aDeliveredMessageSurvivesARoundTrip() throws {
        let message = SessionFixtures.message()

        #expect(try SessionFixtures.roundTrip(message) == message)
    }

    @Test("a delivered message is not read until the inbox marks it")
    func aDeliveredMessageIsUnreadByDefault() {
        let message = SessionMessage(
            id: MailID(),
            from: .user(clientID: "testudo-window-1"),
            to: ULID(),
            text: "Hello.",
            sentAt: SessionFixtures.createdAt,
            chainDepth: 1)

        #expect(message.isRead == false)
        #expect(message.inReplyTo == nil)
    }

    @Test("an outgoing message from a user survives a JSON round trip with its source session")
    func anOutgoingSourceSessionSurvivesARoundTrip() throws {
        let message = OutgoingSessionMessage(
            from: .user(clientID: "testudo-window-1"), to: .session(ULID()), text: "Look at this.",
            sourceSession: ULID())

        #expect(try SessionFixtures.roundTrip(message) == message)
    }

    @Test("an outgoing message in JSON with no source session key decodes with no source session")
    func anOutgoingMessageWithNoSourceSessionKeyDecodes() throws {
        let message = OutgoingSessionMessage(
            from: .user(clientID: "testudo-window-1"), to: .session(ULID()), text: "Look at this.",
            sourceSession: ULID())

        let decoded = try SessionFixtures.decodeWithout(key: "sourceSession", from: message)

        #expect(decoded.sourceSession == nil)
    }

    @Test("a delivered message from a user survives a JSON round trip with its source session")
    func aDeliveredSourceSessionSurvivesARoundTrip() throws {
        let message = Self.deliveredFromUser(sourceSession: ULID())

        #expect(try SessionFixtures.roundTrip(message) == message)
    }

    @Test("a delivered message in JSON with no source session key decodes with no source session")
    func aDeliveredMessageWithNoSourceSessionKeyDecodes() throws {
        let message = Self.deliveredFromUser(sourceSession: ULID())

        let decoded = try SessionFixtures.decodeWithout(key: "sourceSession", from: message)

        #expect(decoded.sourceSession == nil)
    }

    /// A delivered message from a user, in the session `sourceSession`.
    ///
    /// - Parameter sourceSession: The session in which the user wrote the
    ///   message.
    /// - Returns: The delivered message.
    private static func deliveredFromUser(sourceSession: ULID) -> SessionMessage {
        SessionMessage(
            id: MailID(),
            from: .user(clientID: "testudo-window-1"),
            to: ULID(),
            text: "Look at this.",
            sourceSession: sourceSession,
            sentAt: SessionFixtures.createdAt,
            chainDepth: 1)
    }
}
