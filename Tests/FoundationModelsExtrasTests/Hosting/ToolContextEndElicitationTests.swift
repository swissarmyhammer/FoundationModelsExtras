import FoundationModelsExtras
import Testing
import ULID

/// Holds ``ToolContext/endElicitation(_:with:)`` to the public surface: a tool
/// ends an open question of its own run with a decline or a cancel, and the
/// end goes through the run plane as each other end does.
///
/// The import is plain, with no `@testable`. When the member loses `public`,
/// this file does not compile.
@Suite("ToolContext.endElicitation: a tool ends an open question of its own run")
struct ToolContextEndElicitationTests {
    /// The reason of the cancel that the tool gives.
    private static let toolReason = "the tool stopped the flow"

    /// A sink that keeps the id of each question and each end post, in order.
    private actor EndRecordingSink: OperationEventSink {
        /// The id of each question that the sink got.
        nonisolated let asked = Recorder<ULID>()

        /// Each end post: the id of the question and the reason of the answer.
        private(set) var ends: [EndPost] = []

        /// Keeps the id of the question of `event`.
        func post(event: OperationEvent) {
            if let request = event.elicitation {
                asked.append(request.elicitationId)
            }
        }

        /// Keeps the end post.
        func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) {
            ends.append(EndPost(elicitationId: elicitationId, reason: response.reason))
        }
    }

    /// One end post that ``EndRecordingSink`` got.
    private struct EndPost: Equatable {
        /// The id of the question.
        let elicitationId: ULID

        /// The reason of the answer that the run got.
        let reason: String?
    }

    /// One question that a context asks, and what the test needs to end it.
    private struct OpenQuestion {
        /// The run plane of the session.
        let runPlane: RunPlane

        /// The sink of the context.
        let sink: EndRecordingSink

        /// The context that asked the question.
        let context: ToolContext

        /// The question.
        let request: ElicitationRequest

        /// The task of the asker, which ends with its answer.
        let asking: Task<ElicitationResponse, any Error>
    }

    /// Asks one question through a new host context, and returns when the
    /// sink got the question, or when the asker got an answer first. Thus the
    /// wait also ends when the question does not open.
    ///
    /// - Returns: The open question.
    private static func askOneQuestion() async -> OpenQuestion {
        let runPlane = RunPlane()
        let sink = EndRecordingSink()
        let context = MountFixtures.hostContext(on: runPlane, sink: sink)
        let request = MountFixtures.nameRequest()
        let asking = Task { try await context.elicit(request) }
        await Waits.untilFirstEnds({ await sink.asked.waitUntil { !$0.isEmpty } }, { _ = try? await asking.value })
        return OpenQuestion(runPlane: runPlane, sink: sink, context: context, request: request, asking: asking)
    }

    /// Expects that the question is still open, and then ends it, so that no
    /// asker waits after the test.
    ///
    /// - Parameter question: The question.
    private static func expectStillOpen(_ question: OpenQuestion) async {
        let open = await question.runPlane.openElicitations().map(\.elicitationId)
        #expect(open == [question.request.elicitationId])
        _ = await question.runPlane.cancelOpenElicitations()
        _ = try? await question.asking.value
    }

    /// Ends the question when `ended` is `false`, so that the asker does not
    /// wait and the expectations of the test fail.
    ///
    /// - Parameters:
    ///   - question: The question.
    ///   - ended: What ``ToolContext/endElicitation(_:with:)`` gave.
    private static func endWhenStillOpen(_ question: OpenQuestion, ended: Bool) async {
        guard !ended else { return }
        _ = await question.runPlane.cancelOpenElicitations()
    }

    @Test("a cancel with a reason ends an open question of the holding run; the run gets the reason, and one end post goes out")
    func aCancelEndsAnOpenQuestionOfTheHoldingRun() async throws {
        let question = await Self.askOneQuestion()
        let id = question.request.elicitationId

        let ended = await question.context.endElicitation(id, with: .cancel(reason: Self.toolReason))
        await Self.endWhenStillOpen(question, ended: ended)

        #expect(ended)
        #expect(try await question.asking.value == .cancel(reason: Self.toolReason))
        #expect(await question.sink.ends == [EndPost(elicitationId: id, reason: Self.toolReason)])
        #expect(await question.runPlane.openElicitations().isEmpty)
    }

    @Test("a decline with a reason ends an open question of the holding run")
    func aDeclineEndsAnOpenQuestionOfTheHoldingRun() async throws {
        let question = await Self.askOneQuestion()
        let id = question.request.elicitationId

        let ended = await question.context.endElicitation(id, with: .decline(reason: Self.toolReason))
        await Self.endWhenStillOpen(question, ended: ended)

        #expect(ended)
        #expect(try await question.asking.value == .decline(reason: Self.toolReason))
        #expect(await question.sink.ends == [EndPost(elicitationId: id, reason: Self.toolReason)])
    }

    @Test("a question of a different run gives false, and the question stays open")
    func aQuestionOfADifferentRunGivesFalse() async {
        let question = await Self.askOneQuestion()
        let other = MountFixtures.hostContext(on: question.runPlane, sink: question.sink)

        let ended = await other.endElicitation(question.request.elicitationId, with: .cancel(reason: Self.toolReason))

        #expect(!ended)
        #expect(await question.sink.ends.isEmpty)
        await Self.expectStillOpen(question)
    }

    @Test("an accept gives false, and the question stays open")
    func anAcceptGivesFalse() async {
        let question = await Self.askOneQuestion()

        let ended = await question.context.endElicitation(
            question.request.elicitationId, with: .accept(content: ["name": .string("Ada")]))

        #expect(!ended)
        #expect(await question.sink.ends.isEmpty)
        await Self.expectStillOpen(question)
    }

    @Test("a second call for the same question gives false, and posts no second end")
    func aSecondCallGivesFalse() async throws {
        let question = await Self.askOneQuestion()
        let id = question.request.elicitationId
        let first = await question.context.endElicitation(id, with: .cancel(reason: Self.toolReason))
        await Self.endWhenStillOpen(question, ended: first)
        _ = try await question.asking.value

        let second = await question.context.endElicitation(id, with: .cancel(reason: Self.toolReason))

        #expect(first)
        #expect(!second)
        #expect(await question.sink.ends == [EndPost(elicitationId: id, reason: Self.toolReason)])
    }

    @Test("an unknown id gives false")
    func anUnknownIdGivesFalse() async {
        let context = MountFixtures.hostContext(on: RunPlane(), sink: EndRecordingSink())

        #expect(await context.endElicitation(ULID(), with: .cancel(reason: Self.toolReason)) == false)
    }
}
