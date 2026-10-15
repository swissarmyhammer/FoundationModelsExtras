@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Metrics
import MetricsTestKit
import Testing
import ULID

/// Exercises the completion event of a URL flow: the run plane tells the sink
/// of the question through ``OperationEventSink/post(elicitationCompleted:)``
/// when an accepted URL flow completes, and at no other end of a question. A
/// tool ends its own accepted flow with
/// ``ToolContext/complete(elicitationId:)``.
///
/// Each wait reads a stream of events. No test reads a clock or sleeps. To
/// show that an end of a question posts no completion, a test completes a
/// second flow after it, waits for that completion, and then reads each
/// completion that came.
@Suite("Run plane: the completion event of a URL flow")
struct ElicitationCompletionEventTests {
    /// The value of each mounted call.
    private static let callValue = "x"

    /// The questions of one test, and the stream of the sink that they post
    /// to.
    private struct Asking {
        /// The stream of the sink.
        let signals: AsyncStream<ElicitationSignal>

        /// The answer of each question, in the order of the requests.
        let answers: [Task<ElicitationResponse, any Error>]
    }

    /// Asks one question with `request`, then returns the action of the
    /// answer.
    private struct AskingTool: Tool {
        let name = "asking_tool"
        let description = "asks one question, then returns the action of the answer"
        let request: ElicitationRequest

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await context.elicit(request).action.rawValue
        }
    }

    /// Mounts an ``AskingTool`` in a synchronous mount through its own
    /// context, and calls it.
    private struct MountingAskingTool: Tool {
        let name = "mounting_asking_tool"
        let description = "mounts a tool that asks one question, and calls it"
        let request: ElicitationRequest

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await context.mount(AskingTool(request: request)).call(arguments: arguments)
        }
    }

    // MARK: - Helpers

    /// A URL question with a new id.
    ///
    /// - Returns: The question.
    /// - Throws: When the URL does not parse.
    private static func urlRequest() throws -> ElicitationRequest {
        ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: try #require(URL(string: "https://example.com/sign-in")))
    }

    /// Starts one task that asks `request` through a new host context on
    /// `runPlane`, after `gate` opens.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the context.
    ///   - gate: The gate to wait for, or `nil` to ask at once.
    /// - Returns: The task, which gives the answer.
    private static func askingTask(
        _ request: ElicitationRequest, on runPlane: RunPlane, sink: SignallingSink, after gate: RunLatch?
    ) -> Task<ElicitationResponse, any Error> {
        Task {
            await gate?.waitUntilOpen()
            return try await MountFixtures.hostContext(on: runPlane, sink: sink).elicit(request)
        }
    }

    /// Asks each of `requests` at once, and each of `gatedRequests` after
    /// `gate` opens. Each question has its own host context, and all post to
    /// one new ``SignallingSink``. Only the tasks hold the sink.
    ///
    /// - Parameters:
    ///   - requests: The questions to ask at once.
    ///   - runPlane: The run plane of the session.
    ///   - gatedRequests: The questions to ask after `gate` opens.
    ///   - gate: The gate of `gatedRequests`.
    /// - Returns: The stream of the sink and the answers, first `requests`,
    ///   then `gatedRequests`.
    private static func ask(
        _ requests: [ElicitationRequest],
        on runPlane: RunPlane,
        gatedRequests: [ElicitationRequest] = [],
        gate: RunLatch = RunLatch.closed()
    ) -> Asking {
        let sink = SignallingSink()
        let answers =
            requests.map { askingTask($0, on: runPlane, sink: sink, after: nil) }
            + gatedRequests.map { askingTask($0, on: runPlane, sink: sink, after: gate) }
        return Asking(signals: sink.signals, answers: answers)
    }

    /// Mounts `tool` in a synchronous mount on a new site of `runPlane` that
    /// posts to a new ``SignallingSink``, and starts one call. Only the call
    /// holds the sink.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - runPlane: The run plane of the session.
    /// - Returns: The stream of the sink, and the task of the call.
    /// - Throws: When the mounted tool does not keep the types of `tool`.
    private static func call(
        _ tool: any Tool, mountedOn runPlane: RunPlane
    ) throws -> (signals: AsyncStream<ElicitationSignal>, calling: Task<String, any Error>) {
        let sink = SignallingSink()
        let site = MountFixtures.site(runPlane: runPlane, sink: sink)
        let mounted = try #require(
            ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous)
                as? any Tool<MountArguments, String>)
        return (sink.signals, Task { try await mounted.call(arguments: MountArguments(value: callValue)) })
    }

    /// Accepts the URL question of `elicitationId` and completes its flow, as
    /// a host does.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - runPlane: The run plane of the session.
    private static func acceptAndComplete(_ elicitationId: ULID, on runPlane: RunPlane) async {
        #expect(await runPlane.respond(elicitationId: elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(await runPlane.complete(elicitationId: elicitationId) == .completed)
    }

    /// Asks `request` and a second URL question, ends `request` with
    /// `answer`, then completes the flow of the second question. Expects
    /// that the run of `request` gets `delivered`, and that the only
    /// completion is the one of the second question.
    ///
    /// - Parameters:
    ///   - request: The question that `answer` ends.
    ///   - answer: The answer of the host.
    ///   - delivered: The answer that the run of `request` gets.
    /// - Throws: When a task of a question throws.
    private static func expectNoCompletion(
        after answer: ElicitationResponse, to request: ElicitationRequest, delivers delivered: ElicitationResponse
    ) async throws {
        let runPlane = RunPlane()
        let later = try urlRequest()
        let asking = ask([request, later], on: runPlane)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(request.elicitationId), .asked(later.elicitationId)])

        #expect(await runPlane.respond(elicitationId: request.elicitationId, answer) == .delivered)
        #expect(try await asking.answers[0].value == delivered)
        await acceptAndComplete(later.elicitationId, on: runPlane)
        await reader.wait(for: [.completed(later.elicitationId)])

        #expect(reader.completions == [later.elicitationId])
    }

    // MARK: - The completion by the host

    @Test("a host completion of an accepted URL flow posts one completion with its id, and the run gets the accept")
    func aHostCompletionPostsOneCompletion() async throws {
        let runPlane = RunPlane()
        let first = try Self.urlRequest()
        let second = try Self.urlRequest()
        let asking = Self.ask([first, second], on: runPlane)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(first.elicitationId), .asked(second.elicitationId)])

        await Self.acceptAndComplete(first.elicitationId, on: runPlane)
        #expect(try await asking.answers[0].value == .accept(content: nil))
        await Self.acceptAndComplete(second.elicitationId, on: runPlane)
        await reader.wait(for: [.completed(first.elicitationId), .completed(second.elicitationId)])

        #expect(reader.completions.count == 2)
        #expect(Set(reader.completions) == [first.elicitationId, second.elicitationId])
    }

    // MARK: - The ends that post no completion

    @Test("a decline of a URL question posts no completion")
    func aDeclinePostsNoCompletion() async throws {
        let request = try Self.urlRequest()

        try await Self.expectNoCompletion(after: .decline, to: request, delivers: .decline)
    }

    @Test("a cancel of a URL question posts no completion")
    func aCancelPostsNoCompletion() async throws {
        let request = try Self.urlRequest()

        try await Self.expectNoCompletion(after: .cancel, to: request, delivers: .cancel)
    }

    @Test("an accept of a form question posts no completion")
    func aFormAcceptPostsNoCompletion() async throws {
        let answer = ElicitationResponse.accept(content: ["name": .string("Ada")])

        try await Self.expectNoCompletion(after: answer, to: MountFixtures.nameRequest(), delivers: answer)
    }

    @Test("the sweep of an accepted URL question that waits for its completion posts no completion")
    func theSweepPostsNoCompletion() async throws {
        let runPlane = RunPlane()
        let swept = try Self.urlRequest()
        let later = try Self.urlRequest()
        let gate = RunLatch.closed()
        let asking = Self.ask([swept], on: runPlane, gatedRequests: [later], gate: gate)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(swept.elicitationId)])
        #expect(await runPlane.respond(elicitationId: swept.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        #expect(await runPlane.sweep().isEmpty)
        #expect(try await asking.answers[0].value == .cancel(reason: RunPlane.runCancelledReason))
        gate.open()
        await reader.wait(for: [.asked(later.elicitationId)])
        await Self.acceptAndComplete(later.elicitationId, on: runPlane)
        await reader.wait(for: [.completed(later.elicitationId)])

        #expect(reader.completions == [later.elicitationId])
    }

    // MARK: - The completion by the tool

    @Test("a second task of the tool ends its own accepted URL flow, the run gets the accept, and one completion is posted")
    func aToolEndsItsOwnAcceptedFlow() async throws {
        let runPlane = RunPlane()
        let sink = SignallingSink()
        var reader = SignalReader(sink.signals)
        let context = MountFixtures.hostContext(on: runPlane, sink: sink)
        let first = try Self.urlRequest()
        let second = try Self.urlRequest()
        let askingFirst = Task { try await context.elicit(first) }
        await reader.wait(for: [.asked(first.elicitationId)])
        #expect(await runPlane.respond(elicitationId: first.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        let delivery = await Task { await context.complete(elicitationId: first.elicitationId) }.value
        try #require(delivery == .completed)
        #expect(try await askingFirst.value == .accept(content: nil))
        let askingSecond = Task { try await context.elicit(second) }
        await reader.wait(for: [.asked(second.elicitationId)])
        #expect(await runPlane.respond(elicitationId: second.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(await context.complete(elicitationId: second.elicitationId) == .completed)
        #expect(try await askingSecond.value == .accept(content: nil))
        await reader.wait(for: [.completed(first.elicitationId), .completed(second.elicitationId)])

        #expect(reader.completions.count == 2)
        #expect(Set(reader.completions) == [first.elicitationId, second.elicitationId])
    }

    @Test("a context does not end the accepted URL flow of a question of another run")
    func aContextDoesNotEndTheFlowOfAnotherRun() async throws {
        let runPlane = RunPlane()
        let sink = SignallingSink()
        var reader = SignalReader(sink.signals)
        let asker = MountFixtures.hostContext(on: runPlane, sink: sink)
        let other = MountFixtures.hostContext(on: runPlane, sink: sink)
        let request = try Self.urlRequest()
        let asking = Task { try await asker.elicit(request) }
        await reader.wait(for: [.asked(request.elicitationId)])
        #expect(await runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        #expect(await other.complete(elicitationId: request.elicitationId) == .noPendingElicitation)
        #expect(
            await runPlane.openElicitations()
                == [OpenElicitation(elicitationId: request.elicitationId, runToken: asker.completionToken)])
        try #require(await asker.complete(elicitationId: request.elicitationId) == .completed)
        #expect(try await asking.value == .accept(content: nil))
        await reader.wait(for: [.completed(request.elicitationId)])

        #expect(reader.completions == [request.elicitationId])
    }

    // MARK: - A nested mount

    @Test("the completion of a question that a nested synchronous mount asked reaches the sink of the session")
    func theCompletionOfANestedQuestionReachesTheSessionSink() async throws {
        let runPlane = RunPlane()
        let request = try Self.urlRequest()
        let mounted = try Self.call(MountingAskingTool(request: request), mountedOn: runPlane)
        var reader = SignalReader(mounted.signals)
        await reader.wait(for: [.asked(request.elicitationId)])

        await Self.acceptAndComplete(request.elicitationId, on: runPlane)
        #expect(try await mounted.calling.value == ElicitationResponse.Action.accept.rawValue)
        await reader.wait(for: [.completed(request.elicitationId)])

        #expect(reader.completions == [request.elicitationId])
    }

    // MARK: - The order of the completion and the resumed run

    /// The detail of the progress event that a resumed run posts at once.
    private static let resumedDetail = "after"

    /// The depth of the elicitation queue when no question is open.
    private static let noOpenQuestion: Double = 0

    /// The dimensions of the queue metrics of the questions.
    private static var elicitationQueue: [(String, String)] {
        QueueMetricDimensions.queue(named: QueueName.elicitation.rawValue)
    }

    /// Tells if the run plane gave the answer of the one question that
    /// `metrics` records. The run plane records the depth of the
    /// elicitation queue in the same step as it gives the answer, so the
    /// depth tells it with no wait.
    ///
    /// - Parameter metrics: The factory that the run plane recorded into.
    /// - Returns: `true` when the depth went back to zero.
    /// - Throws: When `metrics` has no depth of the elicitation queue.
    private static func answerWasGiven(in metrics: TestMetrics) throws -> Bool {
        try QueueMetricExpectations.depth(in: metrics, queue: elicitationQueue).last == noOpenQuestion
    }

    /// Proves that the completion of a URL flow reaches the sink before the
    /// first post of the resumed run.
    ///
    /// The sink holds the completion on a gate. While the sink holds it, the
    /// test reads the depth of the elicitation queue, which tells with no
    /// wait if the run has its answer:
    ///
    /// - When the run has no answer, the order is correct. The test opens
    ///   the gate. The sink records the completion, and only after that the
    ///   run resumes and posts.
    /// - When the run has its answer, the run resumed before the completion
    ///   post ended. The test does not open the gate. The resumed run posts,
    ///   that post opens the gate, and the sink records the post before the
    ///   completion.
    ///
    /// In each case the stream gets both signals, so the test does not hang.
    /// The order of the two signals then gives the result, with no clock
    /// and no race.
    @Test("the completion of an accepted URL flow reaches the sink before the first post of the resumed run")
    func theCompletionReachesTheSinkBeforeTheResumedRunPosts() async throws {
        let metrics = TestMetrics()
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let sink = SignallingSink(completionGate: gate)
        var reader = SignalReader(sink.signals)
        let context = MountFixtures.hostContext(on: runPlane, sink: sink)
        let request = try Self.urlRequest()
        let asking = withMetricsFactory(metrics) {
            Task {
                let answer = try await context.elicit(request)
                await context.progress(Self.resumedDetail)
                return answer
            }
        }
        await reader.wait(for: [.asked(request.elicitationId)])
        await Self.acceptAndComplete(request.elicitationId, on: runPlane)
        await reader.wait(for: [.completionHeld(request.elicitationId)])

        let answeredWhileHeld = try Self.answerWasGiven(in: metrics)
        #expect(!answeredWhileHeld)
        if !answeredWhileHeld {
            gate.open()
        }
        let expectedOrder: [ElicitationSignal] = [.completed(request.elicitationId), .progress(Self.resumedDetail)]
        await reader.wait(for: Set(expectedOrder))

        #expect(reader.history.filter { expectedOrder.contains($0) } == expectedOrder)
        #expect(try await asking.value == .accept(content: nil))
        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: Self.elicitationQueue, outcome: .succeeded, ran: false)
    }

    // MARK: - A stop of the run while the sink holds the completion

    /// Asks `request` through `context`, and appends the answer to `answers`.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - context: The context of the run.
    ///   - answers: Gets the answer.
    private static func recordAnswer(
        to request: ElicitationRequest, through context: ToolContext, in answers: Recorder<ElicitationResponse>
    ) async {
        do {
            answers.append(try await context.elicit(request))
        } catch {
            Issue.record(error, "the question threw")
        }
    }

    /// Starts a background run on `runPlane` with the cooperative canceler.
    /// Its body asks `request` through a host context of the run, and
    /// appends the answer to `answers`.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the context of the run.
    ///   - answers: Gets each answer of the run.
    /// - Returns: The completion token of the run.
    private static func startAskingRun(
        _ request: ElicitationRequest, on runPlane: RunPlane, sink: SignallingSink, answers: Recorder<ElicitationResponse>
    ) async -> String {
        let token = RunPlane.makeCompletionToken()
        let context = MountFixtures.hostContext(on: runPlane, sink: sink, completionToken: token)
        await runPlane.start(
            tool: MountFixtures.hostTool, op: MountFixtures.hostOp, kind: .swiftTask, completionToken: token,
            canceler: nil
        ) {
            await recordAnswer(to: request, through: context, in: answers)
            return OperationEvent.terminal(token: token, outcome: .succeeded)
        }
        return token
    }

    /// Accepts and completes the URL question of a run while the sink holds
    /// the completion on a gate, runs `stop` while the sink holds it, then
    /// opens the gate. Expects that the body of the run ends, that the run
    /// got one answer, the accept, and that the sink got one completion.
    ///
    /// - Parameter stop: Stops the run of the token on the run plane.
    /// - Throws: When the URL of the question does not parse.
    private static func expectOneAccept(whenStoppedBy stop: (RunPlane, String) async -> Void) async throws {
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let sink = SignallingSink(completionGate: gate)
        var reader = SignalReader(sink.signals)
        let answers = Recorder<ElicitationResponse>()
        let request = try urlRequest()
        let token = await startAskingRun(request, on: runPlane, sink: sink, answers: answers)
        await reader.wait(for: [.asked(request.elicitationId)])
        await acceptAndComplete(request.elicitationId, on: runPlane)
        await reader.wait(for: [.completionHeld(request.elicitationId)])

        await stop(runPlane, token)
        gate.open()
        await runPlane.joinRunBodies()
        await reader.wait(for: [.completed(request.elicitationId)])

        #expect(answers.values == [.accept(content: nil)])
        #expect(reader.completions == [request.elicitationId])
    }

    @Test("a run cancel while the sink holds the completion leaves the run one answer, the accept, and the run ends")
    func aRunCancelWhileTheCompletionIsHeldLeavesOneAccept() async throws {
        try await Self.expectOneAccept { runPlane, token in
            #expect(await runPlane.cancel(completionToken: token) != .unknownToken)
        }
    }

    @Test("a sweep while the sink holds the completion leaves the run one answer, the accept, and the run ends")
    func aSweepWhileTheCompletionIsHeldLeavesOneAccept() async throws {
        try await Self.expectOneAccept { runPlane, _ in
            #expect(await runPlane.sweep().count == 1)
        }
    }
}
