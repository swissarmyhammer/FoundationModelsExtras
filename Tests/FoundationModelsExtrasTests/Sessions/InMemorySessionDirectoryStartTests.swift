import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``InMemorySessionDirectory/start(_:)`` resolves the agent and the folder
/// as session.md section 6 says, through the fake launcher.
@Suite("In-memory session directory: start")
struct InMemorySessionDirectoryStartTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    @Test("a start of a known agent gives a live root session that works on its first message")
    func aStartOfAKnownAgentGivesAWorkingRootSession() async throws {
        let directory = Fixtures.makeDirectory()

        let summary = try await directory.start(
            SessionStartRequest(
                agentID: Fixtures.reviewerAgentID,
                workingDirectory: Fixtures.projectFolder,
                firstMessage: "Review the change.",
                tags: ["review"],
                title: "Review",
                origin: .client))

        #expect(summary.agentID == Fixtures.reviewerAgentID)
        #expect(summary.workingDirectory == Fixtures.projectFolder)
        #expect(summary.kind == .root)
        #expect(summary.state == .working)
        #expect(summary.origin == .client)
        #expect(summary.tags == ["review"])
        #expect(summary.title == "Review")
        #expect(summary.isLive)
        #expect(summary.createdAt == Fixtures.now)
        #expect(try await directory.summary(of: summary.id) == summary)
    }

    @Test("an unknown agent throws unknownAgent with the near names")
    func anUnknownAgentThrowsWithNearNames() async throws {
        let directory = Fixtures.makeDirectory()

        await #expect(throws: SessionDirectoryError.unknownAgent("reveiwer", nearNames: ["reviewer"])) {
            try await directory.start(
                SessionStartRequest(agentID: "reveiwer", firstMessage: "Hi.", origin: .tool))
        }
    }

    @Test("an unknown agent with no near name throws unknownAgent with no near names")
    func anUnknownAgentFarFromEachNameHasNoNearNames() async throws {
        let directory = Fixtures.makeDirectory()

        await #expect(throws: SessionDirectoryError.unknownAgent("translator", nearNames: [])) {
            try await directory.start(
                SessionStartRequest(agentID: "translator", firstMessage: "Hi.", origin: .tool))
        }
    }

    @Test("no agent resolves to the default agent")
    func noAgentResolvesToTheDefaultAgent() async throws {
        let directory = Fixtures.makeDirectory()

        let summary = try await directory.start(
            SessionStartRequest(workingDirectory: Fixtures.projectFolder, firstMessage: "Hi.", origin: .tool))

        #expect(summary.agentID == InMemorySessionDirectory.Launcher.defaultAgentID)
    }

    @Test("no folder resolves to the folder of the session that started it")
    func noFolderResolvesToTheFolderOfTheStarter() async throws {
        let directory = Fixtures.makeDirectory()
        let starter = try await directory.start(
            SessionStartRequest(
                agentID: Fixtures.reviewerAgentID, workingDirectory: Fixtures.otherFolder,
                firstMessage: "Plan.", origin: .client))

        let summary = try await directory.start(
            SessionStartRequest(
                agentID: Fixtures.reviewerAgentID, firstMessage: "Build.", startedBy: starter.id, origin: .tool))

        #expect(summary.workingDirectory == Fixtures.otherFolder)
        #expect(summary.startedBy == starter.id)
    }

    @Test("no folder and no starter resolve to the folder of the launcher")
    func noFolderAndNoStarterResolveToTheLauncherFolder() async throws {
        let directory = Fixtures.makeDirectory()

        let summary = try await directory.start(
            SessionStartRequest(agentID: Fixtures.reviewerAgentID, firstMessage: "Hi.", origin: .trigger))

        #expect(summary.workingDirectory == Fixtures.defaultFolder)
    }

    @Test("a starter that is not in the directory throws unknownSession")
    func anUnknownStarterThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let stranger = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.start(
                SessionStartRequest(
                    agentID: Fixtures.reviewerAgentID, firstMessage: "Hi.", startedBy: stranger, origin: .tool))
        }
    }

    @Test("a directory with no launcher throws noLauncher")
    func noLauncherThrows() async throws {
        let directory = InMemorySessionDirectory()

        await #expect(throws: SessionDirectoryError.noLauncher) {
            try await directory.start(
                SessionStartRequest(agentID: Fixtures.reviewerAgentID, firstMessage: "Hi.", origin: .tool))
        }
    }

    @Test("a start tag outside the tag rule throws invalidTag")
    func anInvalidStartTagThrows() async throws {
        let directory = Fixtures.makeDirectory()

        await #expect(throws: SessionDirectoryError.invalidTag("two words")) {
            try await directory.start(
                SessionStartRequest(
                    agentID: Fixtures.reviewerAgentID, workingDirectory: Fixtures.projectFolder,
                    firstMessage: "Hi.", tags: ["two words"], origin: .tool))
        }
    }

    @Test("the summary of an unknown id is nil")
    func theSummaryOfAnUnknownIDIsNil() async throws {
        let directory = Fixtures.makeDirectory()

        #expect(try await directory.summary(of: ULID()) == nil)
    }
}
