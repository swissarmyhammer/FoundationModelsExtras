import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// ``InMemorySessionDirectory/fork(_:)`` makes a new top-level session of
/// kind `fork`, in the folder of its source, with the agent of its source.
@Suite("In-memory session directory: fork")
struct InMemorySessionDirectoryForkTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// The default name of the sessions that the fixtures start.
    private static let sourceName = Fixtures.reviewerAgentID

    /// The name of the first fork of a fixture session.
    private static let firstForkName = "\(sourceName)-fork"

    /// The name of the second fork of a fixture session.
    private static let secondForkName = "\(sourceName)-fork-2"

    /// The first prompt of the forks that start a turn.
    private static let firstPrompt = "Try the other parser."

    /// A position in the history of the source, for the test.
    private static let historyPosition = 3

    /// A position before the start of the history.
    private static let positionBeforeHistory = -1

    /// Makes a fork request from the user.
    ///
    /// - Parameters:
    ///   - source: The id of the source session.
    ///   - cut: The cut. The default is the end of the last completed turn.
    ///   - firstPrompt: The first prompt of the fork. The default is `nil`.
    /// - Returns: The request.
    private static func request(
        of source: ULID,
        cut: SessionForkCut = .lastCompletedTurn,
        firstPrompt: String? = nil
    ) -> SessionForkRequest {
        SessionForkRequest(
            sourceID: source,
            cut: cut,
            firstPrompt: firstPrompt,
            requestedByClient: Fixtures.clientID,
            forker: Fixtures.user)
    }

    @Test("a fork has the kind fork")
    func aForkHasTheKindFork() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        let fork = try await directory.fork(Self.request(of: source))

        #expect(fork.kind == .fork)
    }

    @Test("the parent of a fork is its source")
    func theParentOfAForkIsItsSource() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        let fork = try await directory.fork(Self.request(of: source))

        #expect(fork.parentID == source)
    }

    @Test("a fork works in the folder of its source")
    func aForkWorksInTheFolderOfItsSource() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        let fork = try await directory.fork(Self.request(of: source))

        #expect(fork.workingDirectory == Fixtures.projectFolder)
    }

    @Test("a fork has the agent of its source")
    func aForkHasTheAgentOfItsSource() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        let fork = try await directory.fork(Self.request(of: source))

        #expect(fork.agentID == Fixtures.reviewerAgentID)
    }

    @Test("a fork has the origin fork")
    func aForkHasTheOriginFork() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        let fork = try await directory.fork(Self.request(of: source))

        #expect(fork.origin == .fork)
    }

    @Test("the name of a fork is the slug of the source name with -fork")
    func theNameOfAForkIsTheSourceSlugWithFork() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        let fork = try await directory.fork(Self.request(of: source))

        #expect(fork.title == Self.firstForkName)
    }

    @Test("a second fork of the same source has the name with -fork-2")
    func aSecondForkHasForkTwo() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        _ = try await directory.fork(Self.request(of: source))

        let second = try await directory.fork(Self.request(of: source))

        #expect(second.title == Self.secondForkName)
    }

    @Test("when the first fork is archived, a new fork has the name with -fork again")
    func anArchivedForkDoesNotCount() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        let first = try await directory.fork(Self.request(of: source))
        _ = try await directory.archive(first.id, by: Fixtures.user)

        let next = try await directory.fork(Self.request(of: source))

        #expect(next.title == Self.firstForkName)
    }

    @Test("a fork of an unknown session throws unknownSession")
    func aForkOfAnUnknownSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let stranger = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            _ = try await directory.fork(Self.request(of: stranger))
        }
    }

    @Test("a fork of an archived session throws archivedSession")
    func aForkOfAnArchivedSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        _ = try await directory.archive(source, by: Fixtures.user)

        await #expect(throws: SessionDirectoryError.archivedSession(source)) {
            _ = try await directory.fork(Self.request(of: source))
        }
    }

    @Test("a fork with no first prompt sends only started, with the kind fork, the parent and the client")
    func aForkSendsStarted() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        let stream = directory.events()

        let fork = try await directory.fork(Self.request(of: source))
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.started(fork, requestedByClient: Fixtures.clientID)])
    }

    @Test("a fork with no first prompt is live and idle")
    func aForkWithNoFirstPromptIsIdle() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        let fork = try await directory.fork(Self.request(of: source))

        #expect(fork.state == .idle && fork.isLive)
    }

    @Test("a fork with a first prompt starts a turn: started, then stateChanged to working")
    func aForkWithAFirstPromptStartsATurn() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        let stream = directory.events()

        let fork = try await directory.fork(Self.request(of: source, firstPrompt: Self.firstPrompt))
        let events = await Fixtures.drain(stream, of: directory)

        var idle = fork
        idle.state = .idle
        #expect(
            events == [
                .started(idle, requestedByClient: Fixtures.clientID),
                .stateChanged(id: fork.id, state: .working, lastSummary: nil),
            ])
    }

    @Test("the directory records the request of a fork, with the cut and the first prompt")
    func theDirectoryRecordsTheForkRequest() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        let request = Self.request(
            of: source, cut: .historyPosition(Self.historyPosition), firstPrompt: Self.firstPrompt)

        let fork = try await directory.fork(request)

        #expect(directory.forkRequest(of: fork.id) == request)
    }

    @Test("a session that is not a fork has no recorded fork request")
    func aSessionThatIsNotAForkHasNoForkRequest() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        #expect(directory.forkRequest(of: source) == nil)
    }

    @Test("a history position before the start of the history throws forkCutOutOfRange")
    func aNegativeHistoryPositionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        let cut = SessionForkCut.historyPosition(Self.positionBeforeHistory)

        await #expect(throws: SessionDirectoryError.forkCutOutOfRange(cut)) {
            _ = try await directory.fork(Self.request(of: source, cut: cut))
        }
    }

    @Test("a cut at the calling tool call of a source that does not work throws forkCutOutOfRange")
    func aToolCallCutOfAnIdleSourceThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)

        await #expect(throws: SessionDirectoryError.forkCutOutOfRange(.callingToolCall)) {
            _ = try await directory.fork(Self.request(of: source, cut: .callingToolCall))
        }
    }

    @Test("a cut at the calling tool call of a working source gives a fork")
    func aToolCallCutOfAWorkingSourceGivesAFork() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startWorkingSession(in: directory).id

        let fork = try await directory.fork(Self.request(of: source, cut: .callingToolCall))

        #expect(fork.parentID == source)
    }

    @Test("a fork leaves its source as it was")
    func aForkLeavesItsSourceAsItWas() async throws {
        let directory = Fixtures.makeDirectory()
        let source = try await Fixtures.startIdleSession(in: directory)
        let before = try await directory.summary(of: source)

        _ = try await directory.fork(Self.request(of: source, firstPrompt: Self.firstPrompt))

        #expect(try await directory.summary(of: source) == before)
    }
}
