@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises the end post of each question that the run plane cancels: the
/// sink of the question gets
/// ``OperationEventSink/post(elicitationEnded:response:)`` in order with the
/// events of the run. The end comes after the elicitation event of the
/// question, and before the run resumes and before the canceler of the run.
///
/// Each wait reads a stream of events, or waits on a gate that a step of the
/// test opens. No test reads a clock, sleeps, polls or retries. A sink that
/// holds an end on a gate also opens that gate when a progress event comes,
/// thus a run that resumes in the wrong order releases the end, and the test
/// fails and does not hang.
@Suite("Run plane: the end post of each question that the run plane cancels")
struct ElicitationEndEventTests {
    private typealias Fixtures = MountFixtures

    /// The answer that each question that the run plane cancels gets.
    private static let cancelled = ElicitationResponse.cancel(reason: RunPlane.runCancelledReason)

    /// The detail of the progress event that a run posts when it resumes.
    private static let resumedDetail = "resumed"

    /// The detail of the progress event that the canceler of a run posts.
    private static let cancelerDetail = "canceler"

    /// The end signal of the question of `elicitationId`, with the reason of
    /// a cancel of the run plane.
    ///
    /// - Parameter elicitationId: The id of the question.
    /// - Returns: The signal.
    private static func ended(_ elicitationId: ULID) -> ElicitationSignal {
        .ended(elicitationId, reason: RunPlane.runCancelledReason)
    }

    // MARK: - The end comes after the elicitation event

    /// A sink that holds the elicitation event of one question until a gate
    /// opens, and gives each post to a ``SignallingSink``.
    private struct HoldingAskSink: OperationEventSink {
        /// The sink that gets each post.
        let signalling: SignallingSink

        /// The id of the question whose elicitation event the sink holds.
        let heldId: ULID

        /// The gate that the held event waits for.
        let gate: RunLatch

        /// Opens when the post of the held event starts.
        let entered: RunLatch

        /// Gives `event` to ``signalling``, after ``gate`` opens when it is
        /// the elicitation event of ``heldId``.
        ///
        /// - Parameter event: The event.
        func post(event: OperationEvent) async {
            if event.elicitation?.elicitationId == heldId {
                entered.open()
                await gate.waitUntilOpen()
            }
            await signalling.post(event: event)
        }

        /// Gives the end of the question to ``signalling``.
        ///
        /// - Parameters:
        ///   - elicitationId: The id of the question.
        ///   - response: The answer that the run of the question gets.
        func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) async {
            await signalling.post(elicitationEnded: elicitationId, response: response)
        }
    }

    /// Asks `first` at once, and `held` after `askHeld` opens, through one
    /// ``HoldingAskSink`` that holds the elicitation event of `held` until
    /// the run of `first` has its answer. Only the tasks hold the sink.
    ///
    /// - Parameters:
    ///   - first: The question to ask at once.
    ///   - held: The question whose elicitation event the sink holds.
    ///   - runPlane: The run plane of the session.
    ///   - askHeld: The gate that the question `held` waits for.
    ///   - entered: Opens when the post of the held event starts.
    /// - Returns: The stream of the sink, and the answers of `first` and
    ///   `held`.
    private static func askHoldingSecond(
        _ first: ElicitationRequest, _ held: ElicitationRequest, on runPlane: RunPlane, askHeld: RunLatch,
        entered: RunLatch
    ) -> Asking {
        let signalling = SignallingSink()
        let gate = RunLatch.closed()
        let sink = HoldingAskSink(signalling: signalling, heldId: held.elicitationId, gate: gate, entered: entered)
        let firstAnswer = Asking.askingTask(first, on: runPlane, sink: sink)
        Task {
            _ = await firstAnswer.result
            gate.open()
        }
        let heldAnswer = Asking.askingTask(held, on: runPlane, sink: sink, after: askHeld)
        return Asking(signals: signalling.signals, answers: [firstAnswer, heldAnswer])
    }

    @Test("the end of a question comes after its elicitation event, also when the post of that event is held")
    func theEndComesAfterTheElicitationEvent() async throws {
        let runPlane = RunPlane()
        let first = Fixtures.nameRequest()
        let held = Fixtures.nameRequest()
        let askHeld = RunLatch.closed()
        let entered = RunLatch.closed()
        let asking = Self.askHoldingSecond(first, held, on: runPlane, askHeld: askHeld, entered: entered)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(first.elicitationId)])
        askHeld.open()
        await entered.waitUntilOpen()

        #expect(await runPlane.sweep().isEmpty)
        await reader.wait(for: [Self.ended(first.elicitationId), Self.ended(held.elicitationId)])

        #expect(reader.read(.asked(first.elicitationId), before: Self.ended(first.elicitationId)))
        #expect(reader.read(.asked(held.elicitationId), before: Self.ended(held.elicitationId)))
        for answer in asking.answers {
            #expect(try await answer.value == Self.cancelled)
        }
    }

    // MARK: - The end comes before the run resumes and before the canceler

    /// Appends `step` to `steps`, then posts it as a progress event through
    /// `context`.
    ///
    /// - Parameters:
    ///   - step: The step.
    ///   - steps: Gets the step.
    ///   - context: The context that posts the step.
    private static func record(_ step: String, in steps: Recorder<String>, through context: ToolContext) async {
        steps.append(step)
        await context.progress(step)
    }

    /// Starts a background run on `runPlane` whose body asks `request`
    /// through a host context of the run, and records
    /// ``resumedDetail`` when it has the answer. Its canceler records
    /// ``cancelerDetail``. The context posts to a new ``SignallingSink``
    /// with `endGate`, and only the run holds that sink.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - runPlane: The run plane of the session.
    ///   - endGate: The end gate of the sink.
    ///   - steps: Gets each step of the run and of its canceler.
    ///   - answers: Gets the answer of the run.
    /// - Returns: The stream of the sink, and the completion token of the
    ///   run.
    private static func startStoppableAskingRun(
        _ request: ElicitationRequest, on runPlane: RunPlane, endGate: RunLatch, steps: Recorder<String>,
        answers: Recorder<ElicitationResponse>
    ) async -> (signals: AsyncStream<ElicitationSignal>, token: String) {
        let sink = SignallingSink(endGate: endGate)
        let token = RunPlane.makeCompletionToken()
        let context = Fixtures.hostContext(on: runPlane, sink: sink, completionToken: token)
        await runPlane.start(
            tool: Fixtures.hostTool, op: Fixtures.hostOp, kind: .swiftTask, completionToken: token,
            canceler: {
                await record(cancelerDetail, in: steps, through: context)
                return .cancelled
            }
        ) {
            await Fixtures.recordAnswer(to: request, through: context, in: answers)
            await record(resumedDetail, in: steps, through: context)
            return OperationEvent.terminal(token: token, outcome: .cancelled)
        }
        return (sink.signals, token)
    }

    /// Stops an asking run with `stop` while the sink holds the end of its
    /// question. Expects that neither the run nor its canceler did a step
    /// while the sink held the end, and that the end reached the sink before
    /// each step.
    ///
    /// When a step comes too early, its progress event opens the gate, so
    /// the test fails and does not hang.
    ///
    /// - Parameter stop: Stops the run of the token on the run plane.
    private static func expectEndBeforeResumeAndCanceler(
        stoppedBy stop: @escaping @Sendable (RunPlane, String) async -> Void
    ) async {
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let steps = Recorder<String>()
        let answers = Recorder<ElicitationResponse>()
        let request = Fixtures.nameRequest()
        let run = await startStoppableAskingRun(request, on: runPlane, endGate: gate, steps: steps, answers: answers)
        var reader = SignalReader(run.signals)
        await reader.wait(for: [.asked(request.elicitationId)])

        let stopping = Task { await stop(runPlane, run.token) }
        await reader.wait(for: [.endHeld(request.elicitationId)])
        let stepsWhileHeld = steps.values
        #expect(stepsWhileHeld.isEmpty)
        if stepsWhileHeld.isEmpty {
            gate.open()
        }
        let ended = ended(request.elicitationId)
        await reader.wait(for: [ended, .progress(resumedDetail), .progress(cancelerDetail)])
        await stopping.value
        await runPlane.joinRunBodies()

        #expect(reader.read(ended, before: .progress(resumedDetail)))
        #expect(reader.read(ended, before: .progress(cancelerDetail)))
        #expect(answers.values == [cancelled])
    }

    @Test("a cancel of the run posts the end before the run resumes and before the canceler runs")
    func aCancelPostsTheEndBeforeTheRunResumesAndBeforeTheCanceler() async {
        await Self.expectEndBeforeResumeAndCanceler { runPlane, token in
            _ = await runPlane.cancel(completionToken: token)
        }
    }

    @Test("the sweep posts the end before the run resumes and before the canceler runs")
    func theSweepPostsTheEndBeforeTheRunResumesAndBeforeTheCanceler() async {
        await Self.expectEndBeforeResumeAndCanceler { runPlane, _ in
            _ = await runPlane.sweep()
        }
    }

    // MARK: - The lists while the end post is in progress

    @Test("while the sink holds the end, the question is ending and not open, and after the end it is in neither list")
    func aHeldEndShowsTheQuestionAsEnding() async throws {
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let request = Fixtures.nameRequest()
        let asking = Asking.start([request], on: runPlane, endGate: gate)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(request.elicitationId)])

        let cancelling = Task { await runPlane.cancelOpenElicitations() }
        await reader.wait(for: [.endHeld(request.elicitationId)])

        #expect(await runPlane.endingElicitations() == [request.elicitationId])
        #expect(await runPlane.openElicitations().isEmpty)
        gate.open()
        #expect(await cancelling.value == [request.elicitationId])
        #expect(try await asking.answers[0].value == Self.cancelled)
        #expect(await runPlane.endingElicitations().isEmpty)
        #expect(await runPlane.openElicitations().isEmpty)
    }

    // MARK: - An answer before and after the cancel step

    @Test("an answer before the cancel step wins, and the run plane posts no end for that question")
    func anAnswerBeforeTheCancelStepWins() async throws {
        let runPlane = RunPlane()
        let answered = Fixtures.nameRequest()
        let later = Fixtures.nameRequest()
        let asking = Asking.start([answered, later], on: runPlane)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(answered.elicitationId), .asked(later.elicitationId)])

        #expect(await runPlane.respond(elicitationId: answered.elicitationId, .decline) == .delivered)
        #expect(await runPlane.cancelOpenElicitations() == [later.elicitationId])
        await reader.wait(for: [Self.ended(later.elicitationId)])

        #expect(try await asking.answers[0].value == .decline)
        #expect(try await asking.answers[1].value == Self.cancelled)
        #expect(reader.ends == [later.elicitationId])
    }

    @Test("an answer and a completion after the cancel step give noPendingElicitation, and the run gets the cancel")
    func anAnswerAfterTheCancelStepFindsNoQuestion() async throws {
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let request = try Fixtures.urlRequest()
        let asking = Asking.start([request], on: runPlane, endGate: gate)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(request.elicitationId)])
        #expect(await runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        let cancelling = Task { await runPlane.cancelOpenElicitations() }
        await reader.wait(for: [.endHeld(request.elicitationId)])

        #expect(reader.history.contains(.endHeld(request.elicitationId)))
        #expect(await runPlane.respond(elicitationId: request.elicitationId, .decline) == .noPendingElicitation)
        #expect(await runPlane.complete(elicitationId: request.elicitationId) == .noPendingElicitation)
        gate.open()
        #expect(await cancelling.value == [request.elicitationId])
        #expect(try await asking.answers[0].value == Self.cancelled)
    }

    // MARK: - cancelOpenElicitations()

    @Test("cancelOpenElicitations() returns the ids only after each end post returned")
    func cancelOpenElicitationsReturnsAfterTheEndPosts() async throws {
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let askLater = RunLatch.closed()
        let first = Fixtures.nameRequest()
        let later = Fixtures.nameRequest()
        let asking = Asking.start([first], on: runPlane, gatedRequests: [later], gate: askLater, endGate: gate)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(first.elicitationId)])
        askLater.open()
        await reader.wait(for: [.asked(later.elicitationId)])
        let returned = Recorder<[ULID]>()

        let cancelling = Task {
            let ended = await runPlane.cancelOpenElicitations()
            returned.append(ended)
            return ended
        }
        await reader.wait(for: [.endHeld(first.elicitationId)])
        #expect(returned.values.isEmpty)
        gate.open()
        let ended = await cancelling.value
        await reader.wait(for: [Self.ended(first.elicitationId), Self.ended(later.elicitationId)])

        #expect(ended == [first.elicitationId, later.elicitationId])
        #expect(reader.ends == ended)
    }

    // MARK: - A question whose completion post is in progress

    @Test("a question whose completion post is in progress gets no end post, and its run gets the accept")
    func aCompletingQuestionGetsNoEnd() async throws {
        let runPlane = RunPlane()
        let completionGate = RunLatch.closed()
        let askLater = RunLatch.closed()
        let completing = try Fixtures.urlRequest()
        let later = Fixtures.nameRequest()
        let asking = Asking.start(
            [completing], on: runPlane, gatedRequests: [later], gate: askLater, completionGate: completionGate)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(completing.elicitationId)])
        #expect(await runPlane.respond(elicitationId: completing.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(await runPlane.complete(elicitationId: completing.elicitationId) == .completed)
        await reader.wait(for: [.completionHeld(completing.elicitationId)])

        #expect(await runPlane.cancelOpenElicitations().isEmpty)
        completionGate.open()
        #expect(try await asking.answers[0].value == .accept(content: nil))
        askLater.open()
        await reader.wait(for: [.asked(later.elicitationId)])
        #expect(await runPlane.cancelOpenElicitations() == [later.elicitationId])
        await reader.wait(for: [Self.ended(later.elicitationId)])

        #expect(reader.ends == [later.elicitationId])
    }

    // MARK: - A run that settles while the end post is in progress

    /// Starts a background run on `runPlane` whose body asks `request` in a
    /// task of its own, and settles when `settle` opens. Its canceler
    /// records ``cancelerDetail`` in `cancels` and opens `settle`. The
    /// context posts to a new ``SignallingSink`` with `endGate`, and only
    /// the run and its question hold that sink.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - runPlane: The run plane of the session.
    ///   - endGate: The end gate of the sink.
    ///   - settle: The gate that the body waits for before it returns.
    ///   - cancels: Gets one value each time the canceler runs.
    /// - Returns: The stream of the sink, and the completion token of the
    ///   run.
    private static func startRunThatSettlesWhileAsking(
        _ request: ElicitationRequest, on runPlane: RunPlane, endGate: RunLatch, settle: RunLatch,
        cancels: Recorder<String>
    ) async -> (signals: AsyncStream<ElicitationSignal>, token: String) {
        let sink = SignallingSink(endGate: endGate)
        let token = RunPlane.makeCompletionToken()
        await runPlane.start(
            tool: Fixtures.hostTool, op: Fixtures.hostOp, kind: .swiftTask, completionToken: token,
            canceler: {
                cancels.append(cancelerDetail)
                settle.open()
                return .cancelled
            }
        ) {
            _ = Asking.askingTask(request, on: runPlane, sink: sink, completionToken: token)
            await settle.waitUntilOpen()
            return OperationEvent.terminal(token: token, outcome: .succeeded)
        }
        return (sink.signals, token)
    }

    @Test("cancel(completionToken:) gives alreadySettled when the run settles while the end post is in progress")
    func aCancelGivesAlreadySettledWhenTheRunSettlesDuringTheEndPost() async throws {
        let runPlane = RunPlane()
        let endGate = RunLatch.closed()
        let settle = RunLatch.closed()
        let cancels = Recorder<String>()
        let request = Fixtures.nameRequest()
        let run = await Self.startRunThatSettlesWhileAsking(
            request, on: runPlane, endGate: endGate, settle: settle, cancels: cancels)
        var reader = SignalReader(run.signals)
        await reader.wait(for: [.asked(request.elicitationId)])

        let cancelling = Task { await runPlane.cancel(completionToken: run.token) }
        await reader.wait(for: [.endHeld(request.elicitationId)])
        settle.open()
        let terminal = try #require(await runPlane.wait(completionToken: run.token, seconds: nil).settledTerminal)
        endGate.open()

        #expect(await cancelling.value == .alreadySettled(terminal))
        #expect(cancels.values.isEmpty)
    }

    // MARK: - A nested mount

    @Test("the end of a question that a nested synchronous mount asked reaches the sink of the session after its event")
    func theEndOfANestedQuestionReachesTheSessionSink() async throws {
        let runPlane = RunPlane()
        let mounted = try Fixtures.callSynchronously(Fixtures.MountingElicitTool(), mountedOn: runPlane)
        var reader = SignalReader(mounted.signals)
        let elicitationId = try #require(await reader.nextAskedId())

        #expect(await runPlane.cancelOpenElicitations() == [elicitationId])
        await reader.wait(for: [Self.ended(elicitationId)])

        #expect(reader.read(.asked(elicitationId), before: Self.ended(elicitationId)))
        #expect(try await mounted.calling.value.contains(ElicitationResponse.Action.cancel.rawValue))
    }

    // MARK: - The mark of a sink post

    /// One post that a ``MarkRecordingSink`` got, with the sink post mark of
    /// the task that ran the post.
    private enum MarkedPost: Equatable {
        /// A post of an event.
        case event(isMarked: Bool)

        /// A post of the completion of a URL flow.
        case completion(isMarked: Bool)

        /// A post of the end of a question.
        case end(isMarked: Bool)
    }

    /// A sink that records, for each post, whether the post runs in a sink
    /// post of the run plane, and then gives the post to a
    /// ``SignallingSink``.
    private struct MarkRecordingSink: OperationEventSink {
        /// Gets each post, with its mark, in post order.
        let marks: Recorder<MarkedPost>

        /// The sink that gets each post after its mark is recorded.
        let signalling: SignallingSink

        /// Records the mark of the current task, then gives `event` to
        /// ``signalling``.
        ///
        /// - Parameter event: The event.
        func post(event: OperationEvent) async {
            marks.append(.event(isMarked: SinkPost.isInProgress))
            await signalling.post(event: event)
        }

        /// Records the mark of the current task, then gives the completion
        /// to ``signalling``.
        ///
        /// - Parameter elicitationId: The id of the question.
        func post(elicitationCompleted elicitationId: ULID) async {
            marks.append(.completion(isMarked: SinkPost.isInProgress))
            await signalling.post(elicitationCompleted: elicitationId)
        }

        /// Records the mark of the current task, then gives the end to
        /// ``signalling``.
        ///
        /// - Parameters:
        ///   - elicitationId: The id of the question.
        ///   - response: The answer that the run of the question gets.
        func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) async {
            marks.append(.end(isMarked: SinkPost.isInProgress))
            await signalling.post(elicitationEnded: elicitationId, response: response)
        }
    }

    /// Asks `request` through a host context on `runPlane` whose sink is the
    /// funnel of a run. The funnel posts to a ``MarkRecordingSink`` that
    /// records in `marks`. Only the task that asks holds the sink.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - runPlane: The run plane of the session.
    ///   - marks: Gets each post of the funnel, with its mark.
    /// - Returns: The stream of the sink, and the answer of `request`.
    private static func askThroughFunnel(
        _ request: ElicitationRequest, on runPlane: RunPlane, marks: Recorder<MarkedPost>
    ) -> Asking {
        let signalling = SignallingSink()
        let token = RunPlane.makeCompletionToken()
        let funnel = RunEventFunnel(
            upstream: MarkRecordingSink(marks: marks, signalling: signalling), runPlane: runPlane,
            completionToken: token)
        let answer = Asking.askingTask(request, on: runPlane, sink: funnel, completionToken: token)
        return Asking(signals: signalling.signals, answers: [answer])
    }

    @Test("a post through the funnel of a run runs with the sink post mark, and its caller runs without it")
    func aFunnelPostRunsWithTheMark() async {
        let marks = Recorder<MarkedPost>()
        let funnel = RunEventFunnel(
            upstream: MarkRecordingSink(marks: marks, signalling: SignallingSink()), runPlane: RunPlane(),
            completionToken: RunPlane.makeCompletionToken())

        await funnel.post(event: OperationEvent.terminal(outcome: .failed))

        #expect(!SinkPost.isInProgress)
        #expect(marks.values == [.event(isMarked: true)])
    }

    @Test("the end post of a question that cancelOpenElicitations() cancels runs with the sink post mark")
    func anEndPostRunsWithTheMark() async throws {
        let runPlane = RunPlane()
        let marks = Recorder<MarkedPost>()
        let request = Fixtures.nameRequest()
        let asking = Self.askThroughFunnel(request, on: runPlane, marks: marks)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(request.elicitationId)])

        #expect(await runPlane.cancelOpenElicitations() == [request.elicitationId])
        #expect(try await asking.answers[0].value == Self.cancelled)

        #expect(!SinkPost.isInProgress)
        #expect(marks.values == [.event(isMarked: true), .end(isMarked: true)])
    }

    @Test("the completion post of an accepted URL flow runs with the sink post mark")
    func aCompletionPostRunsWithTheMark() async throws {
        let runPlane = RunPlane()
        let marks = Recorder<MarkedPost>()
        let request = try Fixtures.urlRequest()
        let asking = Self.askThroughFunnel(request, on: runPlane, marks: marks)
        var reader = SignalReader(asking.signals)
        await reader.wait(for: [.asked(request.elicitationId)])
        #expect(await runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)

        #expect(await runPlane.complete(elicitationId: request.elicitationId) == .completed)
        #expect(try await asking.answers[0].value == .accept(content: nil))

        #expect(!SinkPost.isInProgress)
        #expect(marks.values == [.event(isMarked: true), .completion(isMarked: true)])
    }
}
