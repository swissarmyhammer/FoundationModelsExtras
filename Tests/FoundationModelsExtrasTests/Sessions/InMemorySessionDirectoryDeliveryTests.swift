import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``InMemorySessionDirectory/send(_:)`` follows the delivery rules of
/// session.md section 10.2 and the address rules of section 9.
@Suite("In-memory session directory: delivery")
struct InMemorySessionDirectoryDeliveryTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    @Test("a message to an idle session is delivered and starts a turn")
    func anIdleTargetGetsDelivered() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        let stream = directory.events()

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "Run the tests."))
        let events = await Fixtures.drain(stream, of: directory)

        let receipt = try #require(receipts.first)
        let messageID = try #require(receipt.messageID)
        let delivered = SessionMessage(
            id: messageID, from: Fixtures.user, to: target, text: "Run the tests.",
            sentAt: Fixtures.now, chainDepth: 1)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target, outcome: .delivered)])
        #expect(
            events == [
                .messageDelivered(delivered),
                .stateChanged(id: target, state: .working, lastSummary: nil),
            ])
        #expect(try await directory.summary(of: target)?.state == .working)
    }

    @Test("a message to a working session is queued")
    func aWorkingTargetGetsQueued() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "Also lint."))

        #expect(receipts.map(\.outcome) == [.queued])
        #expect(receipts.map(\.target) == [target])
        #expect(try await directory.inbox(of: target, markRead: false).map(\.text) == ["Also lint."])
    }

    @Test("a message to a session that needs input is queued")
    func aTargetThatNeedsInputGetsQueued() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        try directory.requestInput(of: target)

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "Use the default."))

        #expect(receipts.map(\.outcome) == [.queued])
        #expect(try await directory.summary(of: target)?.state == .needsInput)
    }

    @Test("a queued message that is not read starts the next turn when the turn ends")
    func aQueuedUnreadMessageStartsTheNextTurn() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "Next step."))
        let stream = directory.events()

        try directory.finishTurn(of: target, lastSummary: "First step done.")
        let events = await Fixtures.drain(stream, of: directory)

        #expect(
            events == [
                .stateChanged(id: target, state: .idle, lastSummary: "First step done."),
                .stateChanged(id: target, state: .working, lastSummary: nil),
            ])
    }

    @Test("a queued message that the inbox read starts no turn")
    func aReadQueuedMessageStartsNoTurn() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "Next step."))

        let read = try await directory.inbox(of: target, markRead: true)
        try directory.finishTurn(of: target, lastSummary: "Done.")

        #expect(read.map(\.text) == ["Next step."])
        #expect(try await directory.summary(of: target)?.state == .idle)
    }

    @Test("inbox with markRead marks the messages read, and without it keeps them unread")
    func inboxMarksMessagesRead() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "One."))

        let peeked = try await directory.inbox(of: target, markRead: false)
        let read = try await directory.inbox(of: target, markRead: true)
        let afterRead = try await directory.inbox(of: target, markRead: false)

        #expect(peeked.map(\.text) == ["One."])
        #expect(read.map(\.text) == ["One."])
        #expect(afterRead.isEmpty)
    }

    @Test("the inbox of an unknown session throws unknownSession")
    func theInboxOfAnUnknownSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let stranger = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.inbox(of: stranger, markRead: true)
        }
    }

    @Test("a message to an unknown session id throws unknownSession")
    func anUnknownTargetThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let stranger = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .session(stranger), text: "Hi."))
        }
    }

    @Test("a message to an archived session is refused with the reason archived, and is not delivered")
    func anArchivedTargetIsRefused() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        _ = try await directory.archive(target, by: Fixtures.user)
        let stream = directory.events()

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "Are you there?"))
        let events = await Fixtures.drain(stream, of: directory)

        #expect(receipts == [SessionSendReceipt(target: target, outcome: .refused, reason: "archived")])
        #expect(events.isEmpty)
        #expect(try await directory.inbox(of: target, markRead: false).isEmpty)
    }

    @Test("an archived session with a queued message starts no turn, and no hook changes its state")
    func anArchivedSessionStartsNoTurn() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startWorkingSession(in: directory).id
        _ = try await directory.send(OutgoingSessionMessage(from: Fixtures.user, to: .session(target), text: "Later."))
        let archived = try await directory.archive(target, by: Fixtures.user)
        let stream = directory.events()

        try directory.finishTurn(of: target, lastSummary: nil)
        try directory.startUserTurn(of: target)
        try directory.requestInput(of: target)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(archived.state == .archived)
        #expect(archived.isLive == false)
        #expect(events.isEmpty)
        #expect(try await directory.summary(of: target)?.state == .archived)
    }

    @Test("a second archive of an archived session sends no event")
    func aSecondArchiveSendsNoEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        let first = try await directory.archive(target, by: Fixtures.user)
        let stream = directory.events()

        let second = try await directory.archive(target, by: .session(ULID()))
        let events = await Fixtures.drain(stream, of: directory)

        #expect(second == first)
        #expect(events.isEmpty)
    }

    @Test("an archive of an unknown session throws unknownSession")
    func anArchiveOfAnUnknownSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let stranger = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.archive(stranger, by: Fixtures.user)
        }
    }

    @Test("a message to a recorded session restores it, then delivers")
    func aRecordedTargetIsRestoredThenDelivered() async throws {
        let directory = Fixtures.makeDirectory()
        let recorded = SessionSummary(
            id: ULID(), agentID: Fixtures.reviewerAgentID, workingDirectory: Fixtures.projectFolder,
            tags: [], kind: .root, state: .idle, origin: .client,
            createdAt: Fixtures.now, updatedAt: Fixtures.now, isLive: false)
        directory.register(recorded)
        let stream = directory.events()

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(recorded.id), text: "Resume."))
        let events = await Fixtures.drain(stream, of: directory)

        var restored = recorded
        restored.isLive = true
        #expect(receipts.map(\.outcome) == [.delivered])
        #expect(events.first == .started(restored, requestedByClient: nil))
        #expect(try await directory.summary(of: recorded.id)?.isLive == true)
    }

    @Test("a message to a recorded session with no launcher is refused")
    func aRecordedTargetWithNoLauncherIsRefused() async throws {
        let directory = InMemorySessionDirectory()
        let recorded = SessionSummary(
            id: ULID(), agentID: Fixtures.reviewerAgentID, workingDirectory: Fixtures.projectFolder,
            tags: [], kind: .root, state: .idle, origin: .client,
            createdAt: Fixtures.now, updatedAt: Fixtures.now, isLive: false)
        directory.register(recorded)

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .session(recorded.id), text: "Resume."))

        #expect(
            receipts == [
                SessionSendReceipt(
                    target: recorded.id, outcome: .refused,
                    reason: InMemorySessionDirectory.Refusal.noLauncher.rawValue)
            ])
    }

    @Test("an agent address with no live root session starts one with origin message")
    func anAgentAddressWithNoLiveRootStartsOne() async throws {
        let directory = Fixtures.makeDirectory()
        let sender = try await Fixtures.startWorkingSession(in: directory)
        let stream = directory.events()

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: .session(sender.id), to: .agent(id: "builder", folder: nil), text: "Build it."))
        let events = await Fixtures.drain(stream, of: directory)

        let target = try #require(receipts.first?.target)
        let started = try #require(try await directory.summary(of: target))
        #expect(receipts.map(\.outcome) == [.started])
        #expect(started.agentID == "builder")
        #expect(started.origin == .message)
        #expect(started.startedBy == sender.id)
        #expect(started.workingDirectory == sender.workingDirectory)
        #expect(started.state == .working)
        #expect(events.map(Self.kind) == ["started", "messageDelivered", "stateChanged"])
        #expect(try await directory.inbox(of: started.id, markRead: false).map(\.text) == ["Build it."])
    }

    @Test("an agent address gives the newest live root session of the agent in the folder")
    func anAgentAddressGivesTheNewestLiveRoot() async throws {
        let directory = Fixtures.makeDirectory()
        _ = try await Fixtures.startIdleSession(in: directory)
        let newest = try await Fixtures.startIdleSession(in: directory)

        let receipts = try await directory.send(
            OutgoingSessionMessage(
                from: Fixtures.user, to: .agent(id: Fixtures.reviewerAgentID, folder: Fixtures.projectFolder),
                text: "Review again."))

        #expect(receipts.map(\.target) == [newest])
        #expect(receipts.map(\.outcome) == [.delivered])
    }

    @Test("an agent address in an other folder starts a new session there")
    func anAgentAddressInAnOtherFolderStartsANewSession() async throws {
        let directory = Fixtures.makeDirectory()
        let existing = try await Fixtures.startIdleSession(in: directory)

        let receipts = try await directory.send(
            OutgoingSessionMessage(
                from: Fixtures.user, to: .agent(id: Fixtures.reviewerAgentID, folder: Fixtures.otherFolder),
                text: "Review the other project."))

        let target = try #require(receipts.first?.target)
        #expect(receipts.map(\.outcome) == [.started])
        #expect(target != existing)
        #expect(try await directory.summary(of: target)?.workingDirectory == Fixtures.otherFolder)
    }

    @Test("an agent address with an unknown agent throws unknownAgent")
    func anAgentAddressWithAnUnknownAgentThrows() async throws {
        let directory = Fixtures.makeDirectory()

        await #expect(throws: SessionDirectoryError.unknownAgent("bilder", nearNames: ["builder"])) {
            try await directory.send(
                OutgoingSessionMessage(from: Fixtures.user, to: .agent(id: "bilder", folder: nil), text: "Hi."))
        }
    }

    @Test("an agent address with no launcher and no live root throws noLauncher")
    func anAgentAddressWithNoLauncherThrows() async throws {
        let directory = InMemorySessionDirectory()

        await #expect(throws: SessionDirectoryError.noLauncher) {
            try await directory.send(
                OutgoingSessionMessage(from: Fixtures.user, to: .agent(id: "builder", folder: nil), text: "Hi."))
        }
    }

    @Test("a folder address gives the newest live root session of any agent in the folder")
    func aFolderAddressGivesTheNewestLiveRoot() async throws {
        let directory = Fixtures.makeDirectory()
        let target = try await Fixtures.startIdleSession(in: directory)
        let subagent = SessionSummary(
            id: ULID(), agentID: Fixtures.reviewerAgentID, workingDirectory: Fixtures.projectFolder,
            tags: [], kind: .subagent, state: .idle, parentID: target, origin: .tool,
            createdAt: Fixtures.now, updatedAt: Fixtures.now, isLive: true)
        directory.register(subagent)

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .folder(Fixtures.projectFolder), text: "Status?"))

        #expect(receipts.map(\.target) == [target])
        #expect(receipts.map(\.outcome) == [.delivered])
    }

    @Test("a folder address with no live root session is refused with the hint")
    func aFolderAddressWithNoMatchIsRefused() async throws {
        let directory = Fixtures.makeDirectory()

        let receipts = try await directory.send(
            OutgoingSessionMessage(from: Fixtures.user, to: .folder(Fixtures.otherFolder), text: "Status?"))

        #expect(receipts == [SessionSendReceipt(outcome: .refused, reason: "Name an agent: @agent:/path.")])
    }

    @Test("the mail of a UI message is a user message, and the mail of a session message is an agent message")
    func theMailFollowsTheBodyChoiceRule() {
        let sender = ULID()
        let fromUser = SessionMessage(
            id: MailID(), from: Fixtures.user, to: ULID(), text: "Hi.", sentAt: Fixtures.now, chainDepth: 1)
        let fromSession = SessionMessage(
            id: MailID(), from: .session(sender), to: ULID(), text: "Done.", sentAt: Fixtures.now, chainDepth: 2)

        let userMail = InMemorySessionDirectory.mail(carrying: fromUser)
        let sessionMail = InMemorySessionDirectory.mail(carrying: fromSession)

        #expect(userMail == Mail(id: fromUser.id, sender: .user, body: .userMessage(prompt: "Hi.", options: UserMessageOptions())))
        #expect(
            sessionMail
                == Mail(id: fromSession.id, sender: .session(sender), body: .agentMessage(from: sender, content: "Done.")))
    }

    /// The name of the case of an event.
    ///
    /// - Parameter event: An event.
    /// - Returns: The case name.
    private static func kind(of event: SessionDirectoryEvent) -> String {
        switch event {
        case .started: "started"
        case .factsChanged: "factsChanged"
        case .stateChanged: "stateChanged"
        case .messageDelivered: "messageDelivered"
        case .archived: "archived"
        }
    }
}
