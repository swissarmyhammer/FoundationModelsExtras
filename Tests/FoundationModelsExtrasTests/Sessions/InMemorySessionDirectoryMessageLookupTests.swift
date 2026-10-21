import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``InMemorySessionDirectory/message(_:to:)`` finds a delivered message by
/// its id, read or unread, only for the session that it went to.
@Suite("In-memory session directory: message lookup")
struct InMemorySessionDirectoryMessageLookupTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    @Test("an unread message is found for its recipient, and the lookup leaves it unread")
    func anUnreadMessageIsFoundAndStaysUnread() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        let messageID = try await Self.send("Also lint.", to: target, in: directory)

        let found = try await directory.message(messageID, to: target)

        #expect(
            found
                == SessionMessage(
                    id: messageID, from: Fixtures.user, to: target, text: "Also lint.",
                    sentAt: Fixtures.now, chainDepth: 1))
        #expect(try await directory.inbox(of: target, markRead: false).map(\.id) == [messageID])
    }

    @Test("a message that the inbox read is still found, marked read")
    func aReadMessageIsStillFound() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        let messageID = try await Self.send("Next step.", to: target, in: directory)
        _ = try await directory.inbox(of: target, markRead: true)

        let found = try await directory.message(messageID, to: target)

        #expect(found?.id == messageID)
        #expect(found?.isRead == true)
    }

    @Test("a message that went to another session gives nil")
    func aMessageToAnotherSessionGivesNil() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        let other = try await Fixtures.startWorkingSession(in: directory).id
        let messageID = try await Self.send("Private.", to: target, in: directory)

        #expect(try await directory.message(messageID, to: other) == nil)
    }

    @Test("an unknown message id gives nil")
    func anUnknownIDGivesNil() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await Self.send("Hello.", to: target, in: directory)

        #expect(try await directory.message(MailID(), to: target) == nil)
    }

    /// Sends a message from the UI to one session.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - target: The session to send it to.
    ///   - directory: The directory of the session.
    /// - Returns: The id of the delivered message.
    private static func send(
        _ text: String,
        to target: ULID,
        in directory: InMemorySessionDirectory
    ) async throws -> MailID {
        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: text))
        return try #require(receipts.first?.messageID)
    }
}
