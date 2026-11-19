import Foundation
import FoundationModels
import Testing
import ULID

@testable import FoundationModelsExtras

/// ``InMemorySessionDirectory/importSession(_:transcript:)`` makes a
/// recorded root session from the record of another agent.
@Suite("In-memory session directory: import a session")
struct InMemorySessionDirectoryImportTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// The title of the imported sessions.
    private static let title = "Fix the parser"

    /// The slug of ``title``.
    private static let titleSlug = "fix-the-parser"

    /// The text of the prompt in the imported history.
    private static let promptText = "Why does the parser fail?"

    /// The time of the last record of the source.
    private static let sourceLastDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// The provenance of the imported sessions.
    private static let provenance = SessionImportProvenance(
        agent: "claude-code",
        sourceID: "5f1c2a9e",
        sourcePath: "/Users/someone/.claude/projects/p/5f1c2a9e.jsonl",
        sourceLastDate: sourceLastDate,
        importedAt: Fixtures.now,
        skippedRecordCount: 2)

    /// An import request in the project folder.
    private static let request = SessionImportRequest(
        workingDirectory: Fixtures.projectFolder, title: title, provenance: provenance)

    /// A history with one prompt.
    private static let transcript = Transcript(entries: [
        .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: promptText))]))
    ])

    @Test("an import makes an idle root session that is recorded, with the origin import and the provenance")
    func anImportMakesARecordedRootSession() async throws {
        let directory = Fixtures.makeDirectory()

        let summary = try await directory.importSession(Self.request, transcript: Self.transcript)

        #expect(summary.kind == .root)
        #expect(summary.origin == .import)
        #expect(summary.state == .idle)
        #expect(!summary.isLive)
        #expect(summary.importedFrom == Self.provenance)
        #expect(summary.title == Self.title)
        #expect(summary.workingDirectory == Fixtures.projectFolder)
        #expect(try await directory.summary(of: summary.id) == summary)
    }

    @Test("an import keeps the history, and sends no event")
    func anImportKeepsTheHistory() async throws {
        let directory = Fixtures.makeDirectory()
        let stream = directory.events()

        let summary = try await directory.importSession(Self.request, transcript: Self.transcript)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(directory.importedTranscript(of: summary.id) == Self.transcript)
        #expect(events.isEmpty)
    }

    @Test("a second import with the same title gets the next free number")
    func aSecondImportGetsTheNextNumber() async throws {
        let directory = Fixtures.makeDirectory()
        _ = try await directory.importSession(Self.request, transcript: Self.transcript)

        let second = try await directory.importSession(Self.request, transcript: Self.transcript)

        #expect(second.title == "\(Self.titleSlug)-2")
    }

    @Test("an import with an unknown agent throws unknownAgent")
    func anImportWithAnUnknownAgentThrows() async throws {
        let directory = Fixtures.makeDirectory()
        var request = Self.request
        request.agentID = "no-such-agent"

        await #expect {
            _ = try await directory.importSession(request, transcript: Self.transcript)
        } throws: { error in
            guard case .unknownAgent(let id, _) = error as? SessionDirectoryError else { return false }
            return id == "no-such-agent"
        }
    }

    @Test("the provenance survives a JSON round trip")
    func theProvenanceSurvivesARoundTrip() throws {
        #expect(try SessionFixtures.roundTrip(Self.provenance) == Self.provenance)
    }

    @Test("the import request survives a JSON round trip")
    func theRequestSurvivesARoundTrip() throws {
        #expect(try SessionFixtures.roundTrip(Self.request) == Self.request)
    }

    @Test("a summary from JSON with no importedFrom was not imported")
    func aSummaryWithNoImportedFromDecodes() throws {
        var summary = SessionFixtures.summary()
        summary.importedFrom = Self.provenance

        let decoded = try SessionFixtures.decodeWithout(key: "importedFrom", from: summary)

        #expect(decoded.importedFrom == nil)
    }
}
