import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``SessionDirectoryEvent`` is one change in the directory.
@Suite("SessionDirectoryEvent: one change in the directory")
struct SessionDirectoryEventTests {
    @Test(
        "each event survives a JSON round trip",
        arguments: [
            SessionDirectoryEvent.started(SessionFixtures.summary(), requestedByClient: "testudo-window-1"),
            .started(SessionFixtures.summary(), requestedByClient: nil),
            .factsChanged(SessionFixtures.summary()),
            .stateChanged(id: ULID(), state: .idle, lastSummary: "The build is green."),
            .stateChanged(id: ULID(), state: .working, lastSummary: nil),
            .messageDelivered(SessionFixtures.message()),
            .archived(id: ULID()),
        ])
    func eachEventSurvivesARoundTrip(event: SessionDirectoryEvent) throws {
        #expect(try SessionFixtures.roundTrip(event) == event)
    }
}
