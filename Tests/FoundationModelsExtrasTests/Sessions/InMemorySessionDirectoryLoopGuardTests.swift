import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``InMemorySessionDirectory/send(_:)`` applies the loop guards of
/// session.md section 10.3, with the defaults and with configured limits.
@Suite("In-memory session directory: loop guards")
struct InMemorySessionDirectoryLoopGuardTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures
    private typealias Refusal = InMemorySessionDirectory.Refusal

    /// A small limit that the configured-limit tests set.
    private static let smallLimit = 2

    @Test("the default guards are those of session.md section 10.3")
    func theDefaultGuardsMatchTheDesign() {
        let guards = InMemorySessionDirectory.LoopGuards()

        #expect(guards.chainDepthLimit == 3)
        #expect(guards.messageLengthLimit == 16 * 1024)
        #expect(guards.tagTargetLimit == 8)
        #expect(guards.sendsPerTurnLimit == 16)
    }

    @Test("a text longer than the default 16 KB throws messageTooLong, and a text at the limit goes")
    func aTextLongerThanTheDefaultLimitThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        let limit = InMemorySessionDirectory.LoopGuards.defaultMessageLengthLimit
        let atLimit = String(repeating: "a", count: limit)
        let overLimit = atLimit + "a"

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: atLimit))

        #expect(receipts.map(\.outcome) == [.delivered])
        await #expect(throws: SessionDirectoryError.messageTooLong(limit: limit)) {
            try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: overLimit))
        }
    }

    @Test("the message length counts UTF-8 bytes, with a configured limit")
    func theMessageLengthCountsUTF8Bytes() async throws {
        let directory = Fixtures.makeDirectory(loopGuards: InMemorySessionDirectory.LoopGuards(messageLengthLimit: 3))
        let target = try await Fixtures.startIdleSession(in: directory)

        await #expect(throws: SessionDirectoryError.messageTooLong(limit: 3)) {
            try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "éé"))
        }
    }

    @Test("a send above the default chain depth 3 is refused")
    func aSendAboveTheDefaultChainDepthIsRefused() async throws {
        let directory = Fixtures.makeDirectory()
        let chain = try await Self.startIdleSessions(count: 4, in: directory)

        let first = try await Self.send(from: Fixtures.user, to: chain[0], in: directory)
        let second = try await Self.send(from: .session(chain[0]), to: chain[1], in: directory)
        let third = try await Self.send(from: .session(chain[1]), to: chain[2], in: directory)
        let fourth = try await Self.send(from: .session(chain[2]), to: chain[3], in: directory)

        #expect([first, second, third].map(\.outcome) == [.delivered, .delivered, .delivered])
        #expect(fourth == SessionSendReceipt(outcome: .refused, reason: Refusal.chainTooDeep.rawValue))
        let depths = try await chain.prefix(3).asyncMap { try await directory.inbox(of: $0, markRead: false) }
        #expect(depths.map { $0.map(\.chainDepth) } == [[1], [2], [3]])
        #expect(try await directory.summary(of: chain[3])?.state == .idle)
    }

    @Test("a configured chain depth refuses the send above it")
    func aConfiguredChainDepthRefusesTheSendAboveIt() async throws {
        let directory = Fixtures.makeDirectory(loopGuards: InMemorySessionDirectory.LoopGuards(chainDepthLimit: 1))
        let chain = try await Self.startIdleSessions(count: 2, in: directory)

        let first = try await Self.send(from: Fixtures.user, to: chain[0], in: directory)
        let second = try await Self.send(from: .session(chain[0]), to: chain[1], in: directory)

        #expect(first.outcome == .delivered)
        #expect(second == SessionSendReceipt(outcome: .refused, reason: Refusal.chainTooDeep.rawValue))
    }

    @Test("a message from a user turn has depth 1")
    func aMessageFromAUserTurnHasDepthOne() async throws {
        let directory = Fixtures.makeDirectory()
        let sessions = try await Self.startIdleSessions(count: 2, in: directory)
        try directory.startUserTurn(of: sessions[0])

        _ = try await Self.send(from: .session(sessions[0]), to: sessions[1], in: directory)

        #expect(try await directory.inbox(of: sessions[1], markRead: false).map(\.chainDepth) == [1])
    }

    @Test("a tag send delivers to at most 8 targets, and refuses the rest")
    func aTagSendDeliversToAtMostTheDefaultTargets() async throws {
        let directory = Fixtures.makeDirectory()
        let limit = InMemorySessionDirectory.LoopGuards.defaultTagTargetLimit
        let tagged = try await Self.startIdleSessions(count: limit + Self.smallLimit, in: directory, tags: ["crew"])

        let receipts = try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .tag("crew"), text: "Stand up."))

        #expect(receipts.map(\.target) == tagged)
        #expect(receipts.prefix(limit).allSatisfy { $0.outcome == .delivered })
        #expect(
            receipts.dropFirst(limit).map(\.reason)
                == Array(repeating: Refusal.tooManyTargets.rawValue, count: Self.smallLimit))
    }

    @Test("a configured tag target limit refuses the targets above it")
    func aConfiguredTagTargetLimitRefusesTheRest() async throws {
        let directory = Fixtures.makeDirectory(
            loopGuards: InMemorySessionDirectory.LoopGuards(tagTargetLimit: Self.smallLimit))
        _ = try await Self.startIdleSessions(count: Self.smallLimit + 1, in: directory, tags: ["crew"])

        let receipts = try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .tag("crew"), text: "Stand up."))

        #expect(receipts.map(\.outcome) == [.delivered, .delivered, .refused])
    }

    @Test("a tag send skips the sender")
    func aTagSendSkipsTheSender() async throws {
        let directory = Fixtures.makeDirectory()
        let sessions = try await Self.startIdleSessions(count: 3, in: directory, tags: ["crew"])

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: .session(sessions[0]), to: .tag("crew"), text: "Done here."))

        #expect(receipts.map(\.target) == Array(sessions.dropFirst()))
    }

    @Test("a tag send with no match gives one refused receipt")
    func aTagSendWithNoMatchIsRefused() async throws {
        let directory = Fixtures.makeDirectory()

        let receipts = try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .tag("nobody"), text: "Hi."))

        #expect(receipts == [SessionSendReceipt(outcome: .refused, reason: Refusal.noSessionHasTheTag.rawValue)])
    }

    @Test("a tag address outside the tag rule throws invalidTag")
    func anInvalidTagAddressThrows() async throws {
        let directory = Fixtures.makeDirectory()

        await #expect(throws: SessionDirectoryError.invalidTag("no spaces")) {
            try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .tag("no spaces"), text: "Hi."))
        }
    }

    @Test("one turn sends at most 16 messages, and a later send of the turn is refused")
    func oneTurnSendsAtMostTheDefaultSends() async throws {
        let directory = Fixtures.makeDirectory()
        let sender = try await Fixtures.startWorkingSession(in: directory).id
        let target = try await Fixtures.startWorkingSession(in: directory).id
        let limit = InMemorySessionDirectory.LoopGuards.defaultSendsPerTurnLimit

        let outcomes = try await (0..<limit).asyncMap { _ in
            try await Self.send(from: .session(sender), to: target, in: directory).outcome
        }
        let over = try await Self.send(from: .session(sender), to: target, in: directory)

        #expect(outcomes == Array(repeating: .queued, count: limit))
        #expect(over == SessionSendReceipt(outcome: .refused, reason: Refusal.tooManySends.rawValue))
    }

    @Test("a configured sends limit counts again from 0 in the next turn")
    func theSendsCountStartsAgainInTheNextTurn() async throws {
        let directory = Fixtures.makeDirectory(loopGuards: InMemorySessionDirectory.LoopGuards(sendsPerTurnLimit: 1))
        let sender = try await Fixtures.startWorkingSession(in: directory).id
        let target = try await Fixtures.startWorkingSession(in: directory).id

        let first = try await Self.send(from: .session(sender), to: target, in: directory)
        let second = try await Self.send(from: .session(sender), to: target, in: directory)
        try directory.finishTurn(of: sender, lastSummary: nil)
        try directory.startUserTurn(of: sender)
        let third = try await Self.send(from: .session(sender), to: target, in: directory)

        #expect([first.outcome, second.outcome, third.outcome] == [.queued, .refused, .queued])
    }

    @Test("a send from an unknown session throws unknownSession")
    func aSendFromAnUnknownSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        let stranger = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.send(OutgoingSessionMessage(from: .session(stranger), to: .session(target), text: "Hi."))
        }
    }

    /// Starts idle sessions of the reviewer agent in the project folder.
    ///
    /// - Parameters:
    ///   - count: The number of sessions.
    ///   - directory: The directory to start them in.
    ///   - tags: The tags of each session. The default is none.
    /// - Returns: The ids of the sessions, the oldest first.
    private static func startIdleSessions(
        count: Int,
        in directory: InMemorySessionDirectory,
        tags: Set<String> = []
    ) async throws -> [ULID] {
        try await (0..<count).asyncMap { _ in try await Fixtures.startIdleSession(in: directory, tags: tags) }
    }

    /// Sends one message to one session, and gives its one receipt.
    ///
    /// - Parameters:
    ///   - sender: The sender.
    ///   - target: The target session.
    ///   - directory: The directory.
    /// - Returns: The receipt of the send.
    private static func send(
        from sender: SessionMessageSender,
        to target: ULID,
        in directory: InMemorySessionDirectory
    ) async throws -> SessionSendReceipt {
        let receipts = try await directory.send(OutgoingSessionMessage(from: sender, to: .session(target), text: "Next."))
        return try #require(receipts.first)
    }
}
