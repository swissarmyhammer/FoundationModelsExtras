import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// The event stream of ``InMemorySessionDirectory`` follows the rules of
/// session.md section 7. Each test reads its stream after
/// ``InMemorySessionDirectory/finishEventStreams()``, thus no test waits on a
/// clock.
@Suite("In-memory session directory: events")
struct InMemorySessionDirectoryEventTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// The events beyond the buffer limit that the buffer test sends.
    private static let overflow = 44

    @Test("a start sends started before the first stateChanged of the session")
    func startedComesBeforeTheFirstStateChanged() async throws {
        let directory = Fixtures.makeDirectory()
        let stream = directory.events()

        let summary = try await directory.start(
            SessionStartRequest(
                agentID: Fixtures.reviewerAgentID, workingDirectory: Fixtures.projectFolder,
                firstMessage: "Review.", requestedByClient: Fixtures.clientID, origin: .client))
        let events = await Fixtures.drain(stream, of: directory)

        var startedSummary = summary
        startedSummary.state = .idle
        #expect(
            events == [
                .started(startedSummary, requestedByClient: Fixtures.clientID),
                .stateChanged(id: summary.id, state: .working, lastSummary: nil),
            ])
    }

    @Test("the end of a turn sends stateChanged with the last summary")
    func theEndOfATurnSendsIdleWithTheLastSummary() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let stream = directory.events()

        try directory.finishTurn(of: id, lastSummary: "The build is green.")
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.stateChanged(id: id, state: .idle, lastSummary: "The build is green.")])
        #expect(try await directory.summary(of: id)?.lastSummary == "The build is green.")
    }

    @Test("tags and a title send factsChanged with the new summary")
    func tagsAndTitleSendFactsChanged() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let stream = directory.events()

        let tagged = try await directory.addTags(["build"], to: id)
        let untagged = try await directory.removeTags(["build"], from: id)
        let titled = try await directory.setTitle("Build", of: id)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.factsChanged(tagged), .factsChanged(untagged), .factsChanged(titled)])
    }

    @Test("a fact call that changes nothing sends no event")
    func aFactCallThatChangesNothingSendsNoEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory, tags: ["build"]).id
        let stream = directory.events()

        _ = try await directory.addTags(["build"], to: id)
        _ = try await directory.removeTags(["docs"], from: id)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.isEmpty)
    }

    @Test("a stream gets only the events after the call")
    func aStreamGetsOnlyTheEventsAfterTheCall() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id

        let stream = directory.events()
        let titled = try await directory.setTitle("Late", of: id)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.factsChanged(titled)])
    }

    @Test("each call makes a new stream, and each stream gets each event")
    func eachCallMakesANewStreamWithEachEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let first = directory.events()
        let second = directory.events()

        let titled = try await directory.setTitle("Shared", of: id)
        let firstEvents = await Fixtures.drain(first, of: directory)
        let secondEvents = await Fixtures.drain(second, of: directory)

        #expect(firstEvents == [.factsChanged(titled)])
        #expect(secondEvents == [.factsChanged(titled)])
    }

    @Test("a slow reader loses the old events and keeps the newest 256")
    func aSlowReaderKeepsTheNewestEvents() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let stream = directory.events()
        let sent = InMemorySessionDirectory.eventBufferLimit + Self.overflow

        for index in 0..<sent {
            _ = try await directory.setTitle("Title \(index)", of: id)
        }
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.count == InMemorySessionDirectory.eventBufferLimit)
        #expect(events.first.flatMap(Self.title) == "Title \(Self.overflow)")
        #expect(events.last.flatMap(Self.title) == "Title \(sent - 1)")
    }

    @Test("an archive sends archived")
    func anArchiveSendsArchived() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startWorkingSession(in: directory).id
        let stream = directory.events()

        _ = try await directory.archive(id, by: Fixtures.user)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events == [.archived(id: id)])
    }

    @Test("a registered subagent sends started with its kind, then its state")
    func aRegisteredSubagentSendsStartedThenItsState() async throws {
        let directory = Fixtures.makeDirectory()
        let parent = try await Fixtures.startWorkingSession(in: directory).id
        let stream = directory.events()
        let subagent = SessionSummary(
            id: ULID(), agentID: Fixtures.reviewerAgentID, workingDirectory: Fixtures.projectFolder,
            tags: [], kind: .subagent, state: .working, parentID: parent, origin: .tool,
            createdAt: Fixtures.now, updatedAt: Fixtures.now, isLive: true)

        directory.register(subagent)
        let events = await Fixtures.drain(stream, of: directory)

        var startedSummary = subagent
        startedSummary.state = .idle
        #expect(
            events == [
                .started(startedSummary, requestedByClient: nil),
                .stateChanged(id: subagent.id, state: .working, lastSummary: nil),
            ])
        #expect(try await directory.summary(of: subagent.id) == subagent)
    }

    /// The title in a `factsChanged` event.
    ///
    /// - Parameter event: An event.
    /// - Returns: The title, or `nil` for an other event.
    private static func title(of event: SessionDirectoryEvent) -> String? {
        if case .factsChanged(let summary) = event { summary.title } else { nil }
    }
}
