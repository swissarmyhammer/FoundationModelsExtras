import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``SessionSummary`` holds the facts of one session.
@Suite("SessionSummary: the facts of one session")
struct SessionSummaryTests {
    @Test("a summary with every field set survives a JSON round trip")
    func aFullSummarySurvivesARoundTrip() throws {
        let summary = SessionFixtures.summary()

        #expect(try SessionFixtures.roundTrip(summary) == summary)
    }

    @Test("a summary with no optional field survives a JSON round trip")
    func aSparseSummarySurvivesARoundTrip() throws {
        let summary = SessionSummary(
            id: ULID(),
            agentID: "folder:/tmp/project",
            workingDirectory: SessionFixtures.folder,
            tags: [],
            kind: .root,
            state: .idle,
            origin: .client,
            createdAt: SessionFixtures.createdAt,
            updatedAt: SessionFixtures.createdAt,
            isLive: false)

        let decoded = try SessionFixtures.roundTrip(summary)

        #expect(decoded == summary)
        #expect(decoded.agentName == nil)
        #expect(decoded.title == nil)
        #expect(decoded.parentID == nil)
        #expect(decoded.startedBy == nil)
        #expect(decoded.lastSummary == nil)
    }
}
