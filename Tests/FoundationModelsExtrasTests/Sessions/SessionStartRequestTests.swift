import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``SessionStartRequest`` asks the directory for a new root session.
@Suite("SessionStartRequest: a request for a new root session")
struct SessionStartRequestTests {
    @Test("a request with every field set survives a JSON round trip")
    func aFullRequestSurvivesARoundTrip() throws {
        let request = SessionStartRequest(
            agentID: "reviewer",
            workingDirectory: SessionFixtures.folder,
            firstMessage: "Review the change.",
            tags: ["review"],
            title: "Review",
            startedBy: ULID(),
            requestedByClient: "testudo-window-1",
            origin: .tool)

        #expect(try SessionFixtures.roundTrip(request) == request)
    }

    @Test("a request with only a first message and an origin leaves the rest to the launcher")
    func aMinimalRequestLeavesTheRestToTheLauncher() throws {
        let request = SessionStartRequest(firstMessage: "Start the build.", origin: .trigger)

        let decoded = try SessionFixtures.roundTrip(request)

        #expect(decoded == request)
        #expect(decoded.agentID == nil)
        #expect(decoded.workingDirectory == nil)
        #expect(decoded.tags.isEmpty)
        #expect(decoded.title == nil)
        #expect(decoded.startedBy == nil)
        #expect(decoded.requestedByClient == nil)
    }
}
