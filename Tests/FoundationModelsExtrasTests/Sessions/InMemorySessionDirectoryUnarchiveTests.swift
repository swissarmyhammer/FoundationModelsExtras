import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// An archive of a session is not final. ``InMemorySessionDirectory``
/// keeps the inbox of an archived session, puts a new message to it into
/// that inbox, and ``InMemorySessionDirectory/unarchive(_:by:)`` makes it a
/// recorded session again.
@Suite("In-memory session directory: unarchive and the inbox of an archived session")
struct InMemorySessionDirectoryUnarchiveTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// The text of the message to the archived session.
    private static let text = "Look at the release notes."

    /// The last summary of the turn that the tests end.
    private static let lastSummary = "First step done."

    @Test("an unarchive makes the session idle and not live, and sends stateChanged and then unarchived")
    func anUnarchiveMakesTheSessionIdle() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        _ = try await directory.archive(id, by: Fixtures.user)
        let stream = directory.events()

        let summary = try await directory.unarchive(id, by: Fixtures.user)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(summary.state == .idle)
        #expect(!summary.isLive)
        #expect(summary.archivedAt == nil)
        #expect(
            events == [
                .stateChanged(id: id, state: .idle, lastSummary: summary.lastSummary),
                .unarchived(id: id),
            ])
    }

    @Test("an archive sets archivedAt to the time of the archive")
    func anArchiveSetsArchivedAt() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)

        let summary = try await directory.archive(id, by: Fixtures.user)

        #expect(summary.archivedAt == Fixtures.now)
    }

    @Test("an unarchive of a session that is not archived sends no event and changes nothing")
    func anUnarchiveOfASessionThatIsNotArchivedChangesNothing() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        let before = try #require(try await directory.summary(of: id))
        let stream = directory.events()

        let summary = try await directory.unarchive(id, by: Fixtures.user)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(summary == before)
        #expect(events.isEmpty)
    }

    @Test("an unarchive of an unknown session throws unknownSession")
    func anUnarchiveOfAnUnknownSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let id = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(id)) {
            _ = try await directory.unarchive(id, by: Fixtures.user)
        }
    }

    @Test("a message to an archived session goes to its inbox, and the session stays archived")
    func aMessageToAnArchivedSessionGoesToItsInbox() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        _ = try await directory.archive(id, by: Fixtures.user)
        let stream = directory.events()

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(id), text: Self.text))
        let events = await Fixtures.drain(stream, of: directory)
        let receipt = try #require(receipts.first)

        #expect(receipts.count == 1)
        #expect(receipt.outcome == .sent)
        #expect(receipt.reason == "archived")
        #expect(receipt.target == id)
        #expect(events.count == 1)
        guard case .messageQueued(let queued) = events.first else {
            Issue.record("expected messageQueued, got \(events)")
            return
        }
        #expect(queued.id == receipt.messageID)
        #expect(try await directory.summary(of: id)?.state == .archived)

        _ = try await directory.unarchive(id, by: Fixtures.user)
        let inbox = try await directory.inbox(of: id, markRead: true)

        #expect(inbox.map(\.id) == [queued.id])
    }

    @Test("an archive of a working session keeps its queued message unread in the inbox")
    func anArchiveKeepsTheQueuedMessage() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(id), text: Self.text))
        let messageID = try #require(receipts.first?.messageID)

        _ = try await directory.archive(id, by: Fixtures.user)
        _ = try await directory.unarchive(id, by: Fixtures.user)
        let inbox = try await directory.inbox(of: id, markRead: false)

        #expect(inbox.map(\.id) == [messageID])
        #expect(inbox.allSatisfy { !$0.isRead })
    }

    @Test("a summary from JSON with no archivedAt is not archived")
    func aSummaryWithNoArchivedAtDecodes() throws {
        var summary = SessionFixtures.summary()
        summary.archivedAt = Date(timeIntervalSince1970: 1_000)

        let decoded = try SessionFixtures.decodeWithout(key: "archivedAt", from: summary)

        #expect(decoded.archivedAt == nil)
    }
}
