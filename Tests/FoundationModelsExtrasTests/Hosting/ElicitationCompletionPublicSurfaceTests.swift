import Foundation
import FoundationModelsExtras
import Testing
import ULID

/// A sink as a caller outside this package writes it: a conformance to the
/// public ``OperationEventSink`` in a file with a plain import. It implements
/// `post(event:)` only, so `post(elicitationCompleted:)` comes from the
/// default. It gives each event to a ``SignallingSink``.
struct EventOnlySink: OperationEventSink {
    /// The sink that gets each event.
    let signalling: SignallingSink

    /// Gives `event` to ``signalling``.
    ///
    /// - Parameter event: The event.
    func post(event: OperationEvent) async {
        await signalling.post(event: event)
    }
}

/// Holds the completion of a URL flow to the public surface:
/// ``OperationEventSink/post(elicitationCompleted:)`` with its default, and
/// ``ToolContext/complete(elicitationId:)``.
///
/// The import is plain, with no `@testable`. When a member loses `public`,
/// this file does not compile.
@Suite("Completion of a URL flow over a plain import")
struct ElicitationCompletionPublicSurfaceTests {
    @Test("a sink with no post(elicitationCompleted:) gets the default, and a tool ends its own accepted URL flow")
    func aToolEndsItsOwnAcceptedFlowThroughThePublicSurface() async throws {
        let runPlane = RunPlane()
        let signalling = SignallingSink()
        var reader = SignalReader(signalling.signals)
        let sink = EventOnlySink(signalling: signalling)
        let request = ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: try #require(URL(string: "https://example.com/sign-in")))
        let context = MountFixtures.hostContext(on: runPlane, sink: sink)
        let sinkAsProtocol: any OperationEventSink = sink
        await sinkAsProtocol.post(elicitationCompleted: request.elicitationId)

        let asking = Task { try await context.elicit(request) }
        await reader.wait(for: [.asked(request.elicitationId)])
        let accepted = await runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil))
        let delivery: ElicitationCompletionDelivery = await context.complete(elicitationId: request.elicitationId)

        #expect(reader.history == [.asked(request.elicitationId)])
        #expect(accepted == .acceptedAwaitingCompletion)
        try #require(delivery == .completed)
        #expect(try await asking.value == .accept(content: nil))
        #expect(await runPlane.openElicitations().isEmpty)
    }
}
