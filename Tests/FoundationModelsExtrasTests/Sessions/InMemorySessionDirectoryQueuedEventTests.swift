import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``InMemorySessionDirectory`` sends `messageQueued` at the send of a
/// message that the target does not take at once. `messageDelivered` comes
/// later, when the target takes the message. The delivery tests cover a send
/// to a recorded target.
@Suite("In-memory session directory: the messageQueued event")
struct InMemorySessionDirectoryQueuedEventTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// The text of the message to the target.
    private static let text = "Next step."

    /// The last summary of the turn that the tests end.
    private static let lastSummary = "First step done."

    @Test("a queued message sends messageQueued at the send and messageDelivered when its turn starts")
    func aQueuedMessageSendsQueuedThenDelivered() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        let stream = directory.events()

        _ = try await Self.send(to: target, in: directory)
        let queued = try #require(try await directory.inbox(of: target, markRead: false).first)
        try directory.finishTurn(of: target, lastSummary: Self.lastSummary)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(
            events == [
                .messageQueued(queued),
                .stateChanged(id: target, state: .idle, lastSummary: Self.lastSummary),
                .messageDelivered(queued),
                .stateChanged(id: target, state: .working, lastSummary: nil),
            ])
    }

    @Test("a message to a session that needs input sends messageQueued at the send")
    func aMessageToASessionThatNeedsInputSendsQueued() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        try directory.requestInput(of: target)
        let stream = directory.events()

        _ = try await Self.send(to: target, in: directory)
        let queued = try #require(try await directory.inbox(of: target, markRead: false).first)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.messageQueued(queued)])
    }

    @Test("a message to an idle session sends no messageQueued")
    func aMessageToAnIdleSessionSendsNoQueued() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        let stream = directory.events()

        _ = try await Self.send(to: target, in: directory)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.compactMap(Self.queuedMessage(of:)).isEmpty)
    }

    /// Sends ``text`` from the user to the session `target`.
    ///
    /// - Parameters:
    ///   - target: The target session.
    ///   - directory: The directory.
    /// - Returns: The receipts of the send.
    /// - Throws: What the send throws.
    private static func send(
        to target: ULID, in directory: InMemorySessionDirectory
    ) async throws -> [SessionSendReceipt] {
        try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: text))
    }

    /// The message of a `messageQueued` event.
    ///
    /// - Parameter event: An event.
    /// - Returns: The message, or `nil` for an other event.
    private static func queuedMessage(of event: SessionDirectoryEvent) -> SessionMessage? {
        guard case .messageQueued(let message) = event else { return nil }
        return message
    }
}
