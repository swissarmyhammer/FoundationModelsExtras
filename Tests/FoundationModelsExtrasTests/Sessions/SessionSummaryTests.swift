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
        #expect(decoded.pinnedAt == nil)
        #expect(decoded.lastUsedAt == nil)
        #expect(!decoded.isPinned)
    }

    @Test("a summary encoded with no pin and no last use decodes as not pinned and not used")
    func aSummaryWithNoPinKeysDecodes() throws {
        let summary = SessionFixtures.summary()
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        object["pinnedAt"] = nil
        object["lastUsedAt"] = nil

        let decoded = try JSONDecoder().decode(
            SessionSummary.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.pinnedAt == nil)
        #expect(decoded.lastUsedAt == nil)
        #expect(!decoded.isPinned)
    }

    @Test("a summary with a pin time is pinned")
    func aPinTimeMeansPinned() {
        #expect(SessionFixtures.summary().isPinned)
    }
}
