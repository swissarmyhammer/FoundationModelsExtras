import Foundation
@testable import FoundationModelsExtras
import Testing

/// The plain enums of the session directory survive JSON, case by case.
@Suite("Session enums: the kind, the state, the origin and the send outcome")
struct SessionEnumTests {
    @Test("each session kind survives a JSON round trip", arguments: SessionKind.allCases)
    func eachKindSurvivesARoundTrip(kind: SessionKind) throws {
        #expect(try SessionFixtures.roundTrip(kind) == kind)
    }

    @Test("each session state survives a JSON round trip", arguments: SessionState.allCases)
    func eachStateSurvivesARoundTrip(state: SessionState) throws {
        #expect(try SessionFixtures.roundTrip(state) == state)
    }

    @Test(
        "each directory origin survives a JSON round trip",
        arguments: [
            SessionDirectoryOrigin.client, .tool, .message, .trigger, .fork,
        ])
    func eachOriginSurvivesARoundTrip(origin: SessionDirectoryOrigin) throws {
        #expect(try SessionFixtures.roundTrip(origin) == origin)
    }

    @Test(
        "each send outcome survives a JSON round trip",
        arguments: [
            SessionSendReceipt.Outcome.delivered, .queued, .started, .refused,
        ])
    func eachOutcomeSurvivesARoundTrip(outcome: SessionSendReceipt.Outcome) throws {
        #expect(try SessionFixtures.roundTrip(outcome) == outcome)
    }

    @Test("the kinds are root, subagent and fork")
    func theKindsAreTheThreeOfTheDesign() {
        #expect(SessionKind.allCases == [.root, .subagent, .fork])
    }

    @Test("the states are working, needsInput, idle and archived")
    func theStatesAreTheFourOfTheDesign() {
        #expect(SessionState.allCases == [.working, .needsInput, .idle, .archived])
    }
}
