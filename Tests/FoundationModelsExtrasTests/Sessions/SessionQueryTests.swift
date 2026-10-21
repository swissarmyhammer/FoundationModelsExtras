import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``SessionQuery`` filters the sessions of the directory.
@Suite("SessionQuery: a filter of the sessions")
struct SessionQueryTests {
    /// A limit that differs from the default.
    private static let customLimit = 5

    @Test("a query with no argument filters nothing, lists live sessions only, and has the default limit")
    func theDefaultQuery() {
        let query = SessionQuery()

        #expect(query.workingDirectory == nil)
        #expect(query.agentID == nil)
        #expect(query.tag == nil)
        #expect(query.kind == nil)
        #expect(query.state == nil)
        #expect(query.parentID == nil)
        #expect(query.startedBy == nil)
        #expect(query.includesRecorded == false)
        #expect(query.limit == SessionQuery.defaultLimit)
    }

    @Test("the default limit is 20, the default of the list operation of the tool")
    func theDefaultLimitIsTwenty() {
        #expect(SessionQuery.defaultLimit == 20)
    }

    @Test("a query with every field set survives a JSON round trip")
    func aFullQuerySurvivesARoundTrip() throws {
        let query = SessionQuery(
            workingDirectory: SessionFixtures.folder,
            agentID: "reviewer",
            tag: "build",
            kind: .subagent,
            state: .working,
            parentID: ULID(),
            startedBy: ULID(),
            includesRecorded: true,
            limit: Self.customLimit)

        #expect(try SessionFixtures.roundTrip(query) == query)
    }

    @Test("the default query survives a JSON round trip")
    func theDefaultQuerySurvivesARoundTrip() throws {
        #expect(try SessionFixtures.roundTrip(SessionQuery()) == SessionQuery())
    }
}
