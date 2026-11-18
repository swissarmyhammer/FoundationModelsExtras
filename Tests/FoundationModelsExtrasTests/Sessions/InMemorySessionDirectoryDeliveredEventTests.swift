import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``InMemorySessionDirectory`` sends `messageDelivered` for a queued
/// message when the target takes it: when its turn starts, or when an inbox
/// read marks it read. The delivery tests cover a send to an idle target.
@Suite("In-memory session directory: the messageDelivered event")
struct InMemorySessionDirectoryDeliveredEventTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// The text of the first message to the target.
    private static let firstText = "Next step."

    /// The text of the second message to the target.
    private static let secondText = "Then lint."

    /// The last summary of the turn that the tests end.
    private static let lastSummary = "First step done."

    @Test("a send to a working session sends no messageDelivered at the send")
    func aSendToAWorkingSessionSendsNoEventAtTheSend() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        let stream = directory.events()

        _ = try await Self.send(Self.firstText, to: target, in: directory)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.isEmpty)
    }

    @Test("two queued messages send two messageDelivered events in the order of the sends")
    func twoQueuedMessagesSendTwoEventsInOrder() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await Self.send(Self.firstText, to: target, in: directory)
        _ = try await Self.send(Self.secondText, to: target, in: directory)
        let stream = directory.events()

        try directory.finishTurn(of: target, lastSummary: Self.lastSummary)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.compactMap(Self.deliveredText(of:)) == [Self.firstText, Self.secondText])
    }

    @Test("an inbox read of a queued message sends messageDelivered at the read")
    func anInboxReadOfAQueuedMessageSendsTheEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await Self.send(Self.firstText, to: target, in: directory)
        let message = try #require(try await Self.unread(to: target, in: directory).first)
        let stream = directory.events()

        _ = try await directory.inbox(of: target, markRead: true)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.messageDelivered(message)])
    }

    @Test("a queued message that an inbox read took sends no second messageDelivered when the turn ends")
    func aReadQueuedMessageSendsOneEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await Self.send(Self.firstText, to: target, in: directory)
        let stream = directory.events()

        _ = try await directory.inbox(of: target, markRead: true)
        try directory.finishTurn(of: target, lastSummary: Self.lastSummary)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.compactMap(Self.deliveredText(of:)) == [Self.firstText])
    }

    @Test("an inbox read of a message that the target took sends no second messageDelivered")
    func anInboxReadOfATakenMessageSendsNoEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        _ = try await Self.send(Self.firstText, to: target, in: directory)
        let stream = directory.events()

        _ = try await directory.inbox(of: target, markRead: true)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.isEmpty)
    }

    @Test("a queued message of a session that is archived before its turn sends no messageDelivered")
    func anArchiveBeforeTheTurnSendsNoEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await Self.send(Self.firstText, to: target, in: directory)
        let stream = directory.events()

        _ = try await directory.archive(target, by: Fixtures.user)
        try directory.finishTurn(of: target, lastSummary: Self.lastSummary)
        _ = try await directory.inbox(of: target, markRead: true)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.archived(id: target)])
    }

    /// Sends `text` from the user to the session `target`.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - target: The target session.
    ///   - directory: The directory.
    /// - Returns: The receipts of the send.
    /// - Throws: What the send throws.
    private static func send(
        _ text: String, to target: ULID, in directory: InMemorySessionDirectory
    ) async throws -> [SessionSendReceipt] {
        try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: text))
    }

    /// The messages to `target` that are not read. It marks nothing read.
    ///
    /// - Parameters:
    ///   - target: The target session.
    ///   - directory: The directory.
    /// - Returns: The messages, the oldest first.
    /// - Throws: What the inbox throws.
    private static func unread(
        to target: ULID, in directory: InMemorySessionDirectory
    ) async throws -> [SessionMessage] {
        try await directory.inbox(of: target, markRead: false)
    }

    /// The text of the message of a `messageDelivered` event.
    ///
    /// - Parameter event: An event.
    /// - Returns: The text, or `nil` for an other event.
    private static func deliveredText(of event: SessionDirectoryEvent) -> String? {
        guard case .messageDelivered(let message) = event else { return nil }
        return message.text
    }
}
