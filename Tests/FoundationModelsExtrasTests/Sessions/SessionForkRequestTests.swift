import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// ``SessionForkRequest`` and ``SessionForkCut`` ask the directory for a fork
/// of a session.
@Suite("SessionForkRequest: a request for a fork of a session")
struct SessionForkRequestTests {
    /// A position in the history of the source session, for the test.
    private static let historyPosition = 12

    @Test(
        "each cut survives a JSON round trip",
        arguments: [
            SessionForkCut.lastCompletedTurn,
            .callingToolCall,
            .historyPosition(historyPosition),
            .afterTurn(0),
            .beforeTurn(2),
        ])
    func eachCutSurvivesARoundTrip(cut: SessionForkCut) throws {
        #expect(try SessionFixtures.roundTrip(cut) == cut)
    }

    @Test("a request with every field set survives a JSON round trip")
    func aFullRequestSurvivesARoundTrip() throws {
        let request = SessionForkRequest(
            sourceID: ULID(),
            cut: .historyPosition(Self.historyPosition),
            firstPrompt: "Try the other parser.",
            requestedByClient: "testudo-window-1",
            forker: .user(clientID: "testudo-window-1"))

        #expect(try SessionFixtures.roundTrip(request) == request)
    }

    @Test("a request with no first prompt and no client survives a JSON round trip")
    func aMinimalRequestSurvivesARoundTrip() throws {
        let source = ULID()
        let request = SessionForkRequest(sourceID: source, cut: .callingToolCall, forker: .session(source))

        #expect(try SessionFixtures.roundTrip(request) == request)
    }

    @Test("a request with no first prompt and no client has nil in these fields")
    func aMinimalRequestHasNoFirstPromptAndNoClient() {
        let source = ULID()
        let request = SessionForkRequest(sourceID: source, cut: .lastCompletedTurn, forker: .session(source))

        #expect(request.firstPrompt == nil && request.requestedByClient == nil)
    }
}
