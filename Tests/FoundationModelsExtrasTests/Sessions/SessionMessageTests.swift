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
}
