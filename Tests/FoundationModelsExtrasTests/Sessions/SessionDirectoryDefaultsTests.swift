import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// The defaults of ``SessionDirectory/setPinned(_:of:)``,
/// ``SessionDirectory/markUsed(_:)`` and ``SessionDirectory/fork(_:)`` keep a
/// directory that does not implement them compiling. The defaults of the pin
/// and the last use change nothing. The default of the fork throws.
@Suite("SessionDirectory: the defaults of the pin, the last use and the fork")
struct SessionDirectoryDefaultsTests {
    /// A directory that implements no pin, no last use and no fork. It
    /// forwards each other call to an in-memory directory.
    private struct DirectoryWithNoPins: SessionDirectory {
        let base: InMemorySessionDirectory

        func sessions(matching query: SessionQuery) async throws -> [SessionSummary] {
            try await base.sessions(matching: query)
        }

        func summary(of id: ULID) async throws -> SessionSummary? { try await base.summary(of: id) }

        func start(_ request: SessionStartRequest) async throws -> SessionSummary {
            try await base.start(request)
        }

        func addTags(_ tags: Set<String>, to id: ULID) async throws -> SessionSummary {
            try await base.addTags(tags, to: id)
        }

        func removeTags(_ tags: Set<String>, from id: ULID) async throws -> SessionSummary {
            try await base.removeTags(tags, from: id)
        }

        func setTitle(_ title: String, of id: ULID) async throws -> SessionSummary {
            try await base.setTitle(title, of: id)
        }

        func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt] {
            try await base.send(message)
        }

        func inbox(of id: ULID, markRead: Bool) async throws -> [SessionMessage] {
            try await base.inbox(of: id, markRead: markRead)
        }

        func message(_ id: MailID, to recipient: ULID) async throws -> SessionMessage? {
            try await base.message(id, to: recipient)
        }

        func archive(_ id: ULID, by archiver: SessionMessageSender) async throws -> SessionSummary {
            try await base.archive(id, by: archiver)
        }

        func unarchive(_ id: ULID, by unarchiver: SessionMessageSender) async throws -> SessionSummary {
            try await base.unarchive(id, by: unarchiver)
        }

        func events() -> AsyncStream<SessionDirectoryEvent> { base.events() }
    }

    @Test("the defaults give the summary with no change and send no event")
    func theDefaultsChangeNothing() async throws {
        let base = InMemorySessionDirectoryFixtures.makeDirectory()
        let directory = DirectoryWithNoPins(base: base)
        let id = try await InMemorySessionDirectoryFixtures.startIdleSession(in: base)
        let before = try #require(try await base.summary(of: id))
        let stream = base.events()

        let pinned = try await directory.setPinned(true, of: id)
        let used = try await directory.markUsed(id)
        let events = await InMemorySessionDirectoryFixtures.drain(stream, of: base)

        #expect(pinned == before)
        #expect(used == before)
        #expect(events.isEmpty)
    }

    @Test("the defaults throw unknownSession for an unknown id")
    func theDefaultsThrowForAnUnknownID() async throws {
        let directory = DirectoryWithNoPins(base: InMemorySessionDirectoryFixtures.makeDirectory())
        let id = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(id)) {
            try await directory.setPinned(true, of: id)
        }
        await #expect(throws: SessionDirectoryError.unknownSession(id)) {
            try await directory.markUsed(id)
        }
    }

    @Test("the default fork throws forkUnsupported")
    func theDefaultForkThrows() async throws {
        let base = InMemorySessionDirectoryFixtures.makeDirectory()
        let directory = DirectoryWithNoPins(base: base)
        let source = try await InMemorySessionDirectoryFixtures.startIdleSession(in: base)
        let request = SessionForkRequest(
            sourceID: source, cut: .lastCompletedTurn, forker: InMemorySessionDirectoryFixtures.user)

        await #expect(throws: SessionDirectoryError.forkUnsupported) {
            _ = try await directory.fork(request)
        }
    }
}
