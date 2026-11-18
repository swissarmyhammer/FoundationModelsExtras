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
            .messageQueued(SessionFixtures.message()),
            .messageDelivered(SessionFixtures.message()),
            .archived(id: ULID()),
        ])
    func eachEventSurvivesARoundTrip(event: SessionDirectoryEvent) throws {
        #expect(try SessionFixtures.roundTrip(event) == event)
    }

    /// The JSON of the cases that came before `messageQueued`, as the
    /// synthesized `Codable` form writes them, and the event of each.
    static let oldCaseJSON: [(json: String, event: SessionDirectoryEvent)] = {
        let id = ULID()
        return [
            (
                #"{"stateChanged":{"id":"\#(id.ulidString)","state":"idle","lastSummary":"The build is green."}}"#,
                .stateChanged(id: id, state: .idle, lastSummary: "The build is green.")
            ),
            (#"{"archived":{"id":"\#(id.ulidString)"}}"#, .archived(id: id)),
        ]
    }()

    @Test("the JSON of a case that came before messageQueued still decodes", arguments: oldCaseJSON)
    func theJSONOfAnOldCaseStillDecodes(json: String, event: SessionDirectoryEvent) throws {
        #expect(try JSONDecoder().decode(SessionDirectoryEvent.self, from: Data(json.utf8)) == event)
    }
}
