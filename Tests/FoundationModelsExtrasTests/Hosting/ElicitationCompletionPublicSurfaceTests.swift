import Foundation
import FoundationModelsExtras
import Testing
import ULID

/// A sink as a caller outside this package writes it: a conformance to the
/// public ``OperationEventSink`` in a file with a plain import. It implements
/// `post(event:)` only, so `post(elicitationCompleted:)` comes from the
/// default. It sends the id of each question to a stream.
actor QuestionStreamingSink: OperationEventSink {
    /// The id of each question, in the order that the sink got it.
    nonisolated let questions: AsyncStream<ULID>

    /// Adds an id to ``questions``.
    private let continuation: AsyncStream<ULID>.Continuation

    /// Makes a sink with an empty stream.
    init() {
        (questions, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    /// Sends the id of the question of `event`, when `event` asks one.
    ///
    /// - Parameter event: The event.
    func post(event: OperationEvent) {
        guard let request = event.elicitation else { return }
        continuation.yield(request.elicitationId)
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
        let sink = QuestionStreamingSink()
        let request = ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: try #require(URL(string: "https://example.com/sign-in")))
        let context = ToolContext(
            sessionID: ULID(), runPlane: runPlane, sink: sink, tool: "host_tool", op: "ask user",
            completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
        let sinkAsProtocol: any OperationEventSink = sink
        await sinkAsProtocol.post(elicitationCompleted: request.elicitationId)
        var questions = sink.questions.makeAsyncIterator()

        let asking = Task { try await context.elicit(request) }
        let asked = await questions.next()
        let accepted = await runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil))
        let delivery: ElicitationCompletionDelivery = await context.complete(elicitationId: request.elicitationId)

        #expect(asked == request.elicitationId)
        #expect(accepted == .acceptedAwaitingCompletion)
        try #require(delivery == .completed)
        #expect(try await asking.value == .accept(content: nil))
        #expect(await runPlane.openElicitations().isEmpty)
    }
}
