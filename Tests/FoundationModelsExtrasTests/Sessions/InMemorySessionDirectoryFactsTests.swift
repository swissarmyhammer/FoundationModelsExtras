import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// Tags, titles and queries of ``InMemorySessionDirectory``.
@Suite("In-memory session directory: tags, titles and queries")
struct InMemorySessionDirectoryFactsTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    @Test("addTags adds the tags, and removeTags removes them")
    func tagsAreAddedAndRemoved() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory, tags: ["build"]).id

        let tagged = try await directory.addTags(["kanban:01ABC", "urgent"], to: id)
        let untagged = try await directory.removeTags(["build", "urgent"], from: id)

        #expect(tagged.tags == ["build", "kanban:01ABC", "urgent"])
        #expect(untagged.tags == ["kanban:01ABC"])
        #expect(try await directory.summary(of: id)?.tags == ["kanban:01ABC"])
    }

    @Test("a tag outside the tag rule throws invalidTag")
    func anInvalidTagThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let tooLong = String(repeating: "a", count: InMemorySessionDirectoryState.tagLengthLimit + 1)

        await #expect(throws: SessionDirectoryError.invalidTag("")) {
            try await directory.addTags([""], to: id)
        }
        await #expect(throws: SessionDirectoryError.invalidTag(tooLong)) {
            try await directory.addTags([tooLong], to: id)
        }
        await #expect(throws: SessionDirectoryError.invalidTag("a/b")) {
            try await directory.removeTags(["a/b"], from: id)
        }
    }

    @Test("setTitle sets the title")
    func setTitleSetsTheTitle() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id

        let summary = try await directory.setTitle("Fix the build", of: id)

        #expect(summary.title == "Fix the build")
        #expect(try await directory.summary(of: id)?.title == "Fix the build")
    }

    @Test("a fact change of an unknown session throws unknownSession")
    func aFactChangeOfAnUnknownSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let stranger = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.addTags(["build"], to: stranger)
        }
        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.removeTags(["build"], from: stranger)
        }
        await #expect(throws: SessionDirectoryError.unknownSession(stranger)) {
            try await directory.setTitle("Title", of: stranger)
        }
    }

    @Test("a query gives the matching live sessions, the newest first")
    func aQueryGivesTheMatchingLiveSessionsNewestFirst() async throws {
        let directory = Fixtures.makeDirectory()
        let older = try await Fixtures.startWorkingSession(in: directory, tags: ["build"]).id
        let newer = try await Fixtures.startWorkingSession(in: directory, tags: ["build"]).id
        _ = try await Fixtures.startWorkingSession(in: directory, tags: ["docs"])

        let found = try await directory.sessions(matching: SessionQuery(tag: "build"))

        #expect(found.map(\.id) == [newer, older])
    }

    @Test("a query compares folders after it resolves a trailing slash")
    func aQueryComparesNormalizedFolders() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let withSlash = URL(fileURLWithPath: Fixtures.projectFolder.path + "/")

        let found = try await directory.sessions(matching: SessionQuery(workingDirectory: withSlash))

        #expect(found.map(\.id) == [id])
    }

    @Test("a query filters by agent, kind, state, starter and limit")
    func aQueryFiltersByEachField() async throws {
        let directory = Fixtures.makeDirectory()
        let starter = try await Fixtures.startIdleSession(in: directory)
        let started = try await Fixtures.startWorkingSession(in: directory, startedBy: starter).id

        let byStarter = try await directory.sessions(matching: SessionQuery(startedBy: starter))
        let idle = try await directory.sessions(matching: SessionQuery(state: .idle))
        let reviewers = try await directory.sessions(
            matching: SessionQuery(agentID: Fixtures.reviewerAgentID, kind: .root, limit: 1))
        let subagents = try await directory.sessions(matching: SessionQuery(kind: .subagent))

        #expect(byStarter.map(\.id) == [started])
        #expect(idle.map(\.id) == [starter])
        #expect(reviewers.map(\.id) == [started])
        #expect(subagents.isEmpty)
    }

    @Test("an archived session is found only with includesRecorded")
    func anArchivedSessionIsFoundOnlyWithRecorded() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        _ = try await directory.archive(id, by: Fixtures.user)

        let live = try await directory.sessions(matching: SessionQuery())
        let recorded = try await directory.sessions(matching: SessionQuery(state: .archived, includesRecorded: true))

        #expect(live.isEmpty)
        #expect(recorded.map(\.id) == [id])
    }
}
