@testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises ``ToolContext/transcript(of:)``: a tool reads the recorded events
/// of a session through the reader that the host gave, and the types of the
/// result.
@Suite("Session transcript: a tool reads the recorded events of a session from its context")
struct SessionTranscriptTests {
    /// A reader that gives the transcripts of a fixed set of sessions and
    /// throws ``SessionTranscriptError/notFound(_:)`` for any other id.
    private struct FakeReader: SessionTranscriptReader {
        /// The transcript of each session that the reader knows.
        let known: [ULID: SessionTranscript]

        func transcript(of sessionID: ULID) async throws -> SessionTranscript {
            guard let found = known[sessionID] else { throw SessionTranscriptError.notFound(sessionID) }
            return found
        }
    }

    /// The time of the first entry of ``makeTranscript(of:)``, in seconds
    /// since the reference date. A whole number, so the time survives an
    /// encode and a decode with no loss.
    private static let firstEntryTime: TimeInterval = 1_000

    /// The gap between two entries of ``makeTranscript(of:)``, in seconds.
    private static let entryGap: TimeInterval = 5

    /// A transcript of `sessionID` with two entries, in time order.
    private static func makeTranscript(of sessionID: ULID) -> SessionTranscript {
        SessionTranscript(
            sessionID: sessionID,
            entries: [
                SessionTranscriptEntry(
                    kind: "prompt",
                    timestamp: Date(timeIntervalSinceReferenceDate: firstEntryTime),
                    payload: .object(["text": .string("hello")])),
                SessionTranscriptEntry(
                    kind: "toolCall",
                    timestamp: Date(timeIntervalSinceReferenceDate: firstEntryTime + entryGap),
                    payload: .object(["exitCode": .int(2), "ok": .bool(false)])),
            ])
    }

    /// A context on a session, with `reader` as its transcript source.
    private static func makeContext(reader: (any SessionTranscriptReader)?) -> ToolContext {
        ToolContext(
            sessionID: ULID(), runPlane: RunPlane(), sink: MountFixtures.RecordingSink(), tool: "reader_tool",
            op: "read transcript", completionToken: RunPlane.makeCompletionToken(), isCancelled: { false },
            transcriptReader: reader)
    }

    @Test("a known session id reads its transcript")
    func knownIdReads() async throws {
        let sessionID = ULID()
        let expected = Self.makeTranscript(of: sessionID)
        let context = Self.makeContext(reader: FakeReader(known: [sessionID: expected]))

        #expect(try await context.transcript(of: sessionID) == expected)
    }

    @Test("an unknown session id gives notFound with that id")
    func unknownIdGivesNotFound() async {
        let unknown = ULID()
        let context = Self.makeContext(reader: FakeReader(known: [:]))

        await #expect(throws: SessionTranscriptError.notFound(unknown)) {
            try await context.transcript(of: unknown)
        }
    }

    @Test("a context with no reader gives noSource")
    func missingReaderGivesNoSource() async {
        let context = Self.makeContext(reader: nil)

        await #expect(throws: SessionTranscriptError.noSource) {
            try await context.transcript(of: ULID())
        }
    }

    @Test("a session other than the session of the call reads when the reader knows it")
    func otherSessionReads() async throws {
        let other = ULID()
        let expected = Self.makeTranscript(of: other)
        let context = Self.makeContext(reader: FakeReader(known: [other: expected]))

        #expect(context.sessionID != other)
        #expect(try await context.transcript(of: other) == expected)
    }

    @Test("a context on a mount site reads through the reader of the site")
    func siteReaderReaches() async throws {
        let sessionID = ULID()
        let expected = Self.makeTranscript(of: sessionID)
        let site = MountSite(
            sessionID: ULID(), runPlane: RunPlane(), sink: MountFixtures.RecordingSink(),
            transcriptReader: FakeReader(known: [sessionID: expected]))
        let context = ToolContext(
            calling: MountFixtures.FastTool(), on: site, sink: MountFixtures.RecordingSink(),
            completionToken: RunPlane.makeCompletionToken(), state: ToolCallState())

        #expect(try await context.transcript(of: sessionID) == expected)
    }

    @Test("the site of a child session keeps the reader of its parent")
    func childSiteKeepsReader() async throws {
        let sessionID = ULID()
        let expected = Self.makeTranscript(of: sessionID)
        let root = MountSite(
            sessionID: ULID(), runPlane: RunPlane(), sink: MountFixtures.RecordingSink(),
            transcriptReader: FakeReader(known: [sessionID: expected]))
        let child = root.childSite(sessionID: ULID(), runPlane: RunPlane(), sink: MountFixtures.RecordingSink())
        let context = ToolContext(
            calling: MountFixtures.FastTool(), on: child, sink: MountFixtures.RecordingSink(),
            completionToken: RunPlane.makeCompletionToken(), state: ToolCallState())

        #expect(try await context.transcript(of: sessionID) == expected)
    }

    @Test("a transcript survives a JSON round trip")
    func transcriptRoundTrips() throws {
        let transcript = Self.makeTranscript(of: ULID())

        let decoded = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(transcript))

        #expect(decoded == transcript)
    }

    @Test("an error survives a JSON round trip")
    func errorRoundTrips() throws {
        let error = SessionTranscriptError.notFound(ULID())

        let decoded = try JSONDecoder().decode(SessionTranscriptError.self, from: JSONEncoder().encode(error))

        #expect(decoded == error)
    }
}
