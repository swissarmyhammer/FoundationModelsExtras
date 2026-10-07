@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// The bound ``ToolContext``: the binding through `ToolContext.$current`, the
/// rule that work with no task-local values sees `nil`, the stamps of each
/// event, the `elicit(_:)` round trip through a real ``RunPlane``, and the
/// run-plane capabilities `backgroundRuns()`, `wait` and `cancel` against a
/// fake background run.
@Suite("ToolContext: ambient task-local capability surface", .timeLimit(.minutes(1)))
struct ToolContextTests {
    // MARK: - Fixtures

    /// The tool and the op of each context that
    /// ``makeContext(sink:runPlane:sessionID:completionToken:isCancelled:)``
    /// makes.
    private static let demoToolName = "demo_tool"

    /// The number of characters of a ULID string.
    private static let ulidStringLength = 26

    /// The limit of each wait that a test does on the run plane. A settled
    /// run never waits this long.
    private static let settlementDeadline: Double = 30

    /// A deadline that a run that never settles elapses, while the suite
    /// stays fast.
    private static let elapsingDeadline: Double = 0.05

    /// The arguments of the fixture tools.
    @Generable
    struct ContextToolArguments {
        /// The value that the model sends.
        let value: String
    }

    /// A tool with an empty name. Its context must still stamp a tool and an
    /// op that are not empty.
    private struct EmptyNamedTool: Tool {
        let name = ""
        let description = "test-only tool with an empty name"

        func call(arguments: ContextToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }
    }

    /// A sink that keeps each event, in post order.
    private typealias RecordingSink = MountFixtures.RecordingSink

    /// A sink that answers an elicitation when it sees the event, with no
    /// poll.
    private actor ImmediatelyRespondingSink: OperationEventSink {
        /// The run plane that holds the elicitation.
        private let runPlane: RunPlane

        /// The answer to give.
        private let response: ElicitationResponse

        /// Makes the sink.
        ///
        /// - Parameters:
        ///   - runPlane: The run plane that holds the elicitation.
        ///   - response: The answer to give.
        init(runPlane: RunPlane, response: ElicitationResponse) {
            self.runPlane = runPlane
            self.response = response
        }

        func post(event: OperationEvent) async {
            guard let request = event.elicitation else { return }
            await runPlane.respond(elicitationId: request.elicitationId, response)
        }
    }

    /// A context bound to `sink`, with ``demoToolName`` as its tool and op.
    private static func makeContext(
        sink: any OperationEventSink,
        runPlane: RunPlane = RunPlane(),
        sessionID: ULID = ULID(),
        completionToken: String = RunPlane.makeCompletionToken(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> ToolContext {
        ToolContext(
            sessionID: sessionID,
            runPlane: runPlane,
            sink: sink,
            tool: demoToolName,
            op: demoToolName,
            completionToken: completionToken,
            isCancelled: isCancelled
        )
    }

    /// Waits until each id in `elicitationIds` is pending on `runPlane`. The
    /// time limit of the suite ends a wait for an id that never comes.
    private static func waitUntilPending(_ elicitationIds: [ULID], in runPlane: RunPlane) async throws {
        try await AwaitedCondition.wait {
            let pending = await runPlane.pendingElicitationIds()
            return elicitationIds.allSatisfy(pending.contains)
        }
    }

    /// A form question with one string field.
    private static func formRequest() -> ElicitationRequest {
        ElicitationRequest(
            message: "What is your name?",
            elicitationId: ULID(),
            requestedSchema: ElicitationRequestedSchema(properties: ["name": .string(ElicitationStringSchema())])
        )
    }

    // MARK: - Token

    @Test("the token of the context has the form of the token of the run plane")
    func theContextTokenHasTheRunPlaneTokenForm() {
        let published = ToolContext.makeCompletionToken()
        let runPlaneMade = RunPlane.makeCompletionToken()

        // The run plane keeps a run by this token, and each event carries it
        // as its `correlationID`. A token of a different form names no run.
        #expect(ULID(ulidString: published) != nil)
        #expect(ULID(ulidString: runPlaneMade) != nil)
        #expect(published.count == Self.ulidStringLength)
        #expect(runPlaneMade.count == published.count)
    }

    // MARK: - Binding

    @Test("a body inside withValue sees the bound context; outside it sees nil")
    func bindingVisibility() async throws {
        let sessionID = ULID()
        let completionToken = RunPlane.makeCompletionToken()
        let context = Self.makeContext(sink: RecordingSink(), sessionID: sessionID, completionToken: completionToken)

        #expect(ToolContext.current == nil)
        ToolContext.$current.withValue(context) {
            let current = ToolContext.current
            #expect(current != nil)
            #expect(current?.sessionID == sessionID)
            #expect(current?.completionToken == completionToken)
            #expect(current?.tool == Self.demoToolName)
            #expect(current?.op == Self.demoToolName)
        }
        #expect(ToolContext.current == nil)
    }

    @Test("work that inherits no task-locals, started inside the binding, does not see the context")
    func nonInheritingWorkSeesNil() async throws {
        let context = Self.makeContext(sink: RecordingSink())

        await ToolContext.$current.withValue(context) {
            #expect(ToolContext.current != nil)
            // A thread inherits no task-local values.
            let probeSawContext = await withCheckedContinuation { continuation in
                Thread {
                    continuation.resume(returning: ToolContext.current != nil)
                }.start()
            }
            #expect(!probeSawContext)
        }
    }

    @Test("cancellation reports what the probe of the invoker reports")
    func cancellationReflectsProbe() async throws {
        let live = Self.makeContext(sink: RecordingSink(), isCancelled: { false })
        #expect(!live.isCancelled)

        let cancelled = Self.makeContext(sink: RecordingSink(), isCancelled: { true })
        #expect(cancelled.isCancelled)
    }

    // MARK: - Posting with no context

    @Test("posting through a nil current context does nothing")
    func nilCurrentPostIsNoOp() async throws {
        let sink = RecordingSink()
        // The context is never bound, so `ToolContext.current` stays nil.
        _ = Self.makeContext(sink: sink)

        #expect(ToolContext.current == nil)
        await ToolContext.current?.progress("never delivered")
        await ToolContext.current?.post(
            OperationEvent(
                tool: "", op: "", correlationID: "", kind: .completed,
                detail: "never delivered", outcome: .succeeded
            )
        )

        #expect(await sink.events.isEmpty)
    }

    // MARK: - Stamps

    @Test("progress(_:) posts a .progress event with the identity of the run")
    func progressCarriesRunIdentity() async throws {
        let sink = RecordingSink()
        let completionToken = RunPlane.makeCompletionToken()
        let context = Self.makeContext(sink: sink, completionToken: completionToken)

        await context.progress("halfway")

        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .progress)
        #expect(events.first?.detail == "halfway")
        #expect(events.first?.correlationID == completionToken)
        #expect(events.first?.tool == Self.demoToolName)
        #expect(events.first?.op == Self.demoToolName)
    }

    @Test("message(_:) posts a .message event with the text as its detail, no outcome, and the identity of the run")
    func messageCarriesRunIdentity() async throws {
        let sink = RecordingSink()
        let completionToken = RunPlane.makeCompletionToken()
        let context = Self.makeContext(sink: sink, completionToken: completionToken)

        await context.message("the child found the file")

        let events = await sink.events
        #expect(events.count == 1)
        let posted = try #require(events.first)
        #expect(posted.kind == .message)
        #expect(posted.detail == "the child found the file")
        #expect(posted.outcome == nil)
        #expect(posted.elicitation == nil)
        #expect(posted.correlationID == completionToken)
        #expect(posted.tool == Self.demoToolName)
        #expect(posted.op == Self.demoToolName)
    }

    @Test("a message is not terminal: the run funnel sends it, and the terminal event after it, upstream")
    func aMessageIsNotTerminal() async throws {
        let sink = RecordingSink()
        let completionToken = RunPlane.makeCompletionToken()
        let funnel = RunEventFunnel(upstream: sink, runPlane: RunPlane(), completionToken: completionToken)
        let context = Self.makeContext(sink: funnel, completionToken: completionToken)

        await context.message("first mail")
        await context.message("second mail")
        await context.post(
            OperationEvent(tool: "", op: "", correlationID: "", kind: .completed, detail: "done", outcome: .succeeded))

        let events = await sink.events
        #expect(events.map(\.kind) == [.message, .message, .completed])
        #expect(events.map(\.detail) == ["first mail", "second mail", "done"])
    }

    @Test("a message after the terminal event of the run is dropped")
    func aMessageAfterTheTerminalEventIsDropped() async throws {
        let sink = RecordingSink()
        let completionToken = RunPlane.makeCompletionToken()
        let funnel = RunEventFunnel(upstream: sink, runPlane: RunPlane(), completionToken: completionToken)
        let context = Self.makeContext(sink: funnel, completionToken: completionToken)

        await context.post(
            OperationEvent(tool: "", op: "", correlationID: "", kind: .completed, detail: "done", outcome: .succeeded))
        await context.message("too late")

        let events = await sink.events
        #expect(events.map(\.kind) == [.completed])
    }

    @Test("post(_:) stamps tool, op and correlationID; the tool never gives them")
    func postCarriesRunIdentityWithoutToolSupplyingIt() async throws {
        let sink = RecordingSink()
        let completionToken = RunPlane.makeCompletionToken()
        let context = Self.makeContext(sink: sink, completionToken: completionToken)

        await context.post(
            OperationEvent(
                tool: "", op: "", correlationID: "", kind: .completed,
                detail: "done", outcome: .succeeded
            )
        )

        let events = await sink.events
        #expect(events.count == 1)
        let posted = try #require(events.first)
        #expect(posted.kind == .completed)
        #expect(posted.detail == "done")
        #expect(posted.outcome == .succeeded)
        #expect(posted.tool == Self.demoToolName)
        #expect(posted.op == Self.demoToolName)
        #expect(!posted.tool.isEmpty)
        #expect(!posted.op.isEmpty)
        #expect(posted.correlationID == completionToken)
    }

    // MARK: - Elicitation

    @Test("elicit suspends, posts the request upstream, and resumes on accept with content")
    func elicitAcceptRoundTrip() async throws {
        let sink = RecordingSink()
        let runPlane = RunPlane()
        let completionToken = RunPlane.makeCompletionToken()
        let context = Self.makeContext(sink: sink, runPlane: runPlane, completionToken: completionToken)
        let request = Self.formRequest()

        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await ToolContext.$current.withValue(context) {
                let current = try #require(ToolContext.current)
                return try await current.elicit(request)
            }
        }

        try await Self.waitUntilPending([request.elicitationId], in: runPlane)
        await runPlane.respond(elicitationId: request.elicitationId, .accept(content: ["name": .string("Ada")]))

        let answer = try await answering.deliveredAnswer()
        #expect(answer.action == .accept)
        #expect(answer.content == ["name": .string("Ada")])

        // The request went to the sink as an elicitation event of the run.
        let events = await sink.events
        #expect(events.count == 1)
        let posted = try #require(events.first)
        #expect(posted.kind == .elicitation)
        #expect(posted.elicitation == request)
        #expect(posted.correlationID == completionToken)
        #expect(posted.tool == Self.demoToolName)
        #expect(posted.op == Self.demoToolName)
    }

    @Test("elicit resumes on decline, with no content")
    func elicitDeclineRoundTrip() async throws {
        let runPlane = RunPlane()
        let context = Self.makeContext(sink: RecordingSink(), runPlane: runPlane)
        let request = Self.formRequest()

        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await context.elicit(request)
        }

        try await Self.waitUntilPending([request.elicitationId], in: runPlane)
        await runPlane.respond(elicitationId: request.elicitationId, .decline)

        let answer = try await answering.deliveredAnswer()
        #expect(answer.action == .decline)
        #expect(answer.content == nil)
    }

    @Test("elicit resumes on cancel, with no content")
    func elicitCancelRoundTrip() async throws {
        let runPlane = RunPlane()
        let context = Self.makeContext(sink: RecordingSink(), runPlane: runPlane)
        let request = Self.formRequest()

        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await context.elicit(request)
        }

        try await Self.waitUntilPending([request.elicitationId], in: runPlane)
        await runPlane.respond(elicitationId: request.elicitationId, .cancel)

        let answer = try await answering.deliveredAnswer()
        #expect(answer.action == .cancel)
        #expect(answer.content == nil)
    }

    @Test("two concurrent elicitations on one run resolve independently by elicitationId")
    func concurrentDoubleElicit() async throws {
        let sink = RecordingSink()
        let runPlane = RunPlane()
        let context = Self.makeContext(sink: sink, runPlane: runPlane)
        let first = Self.formRequest()
        let second = Self.formRequest()

        let firstAnswering = AnswerDrivenRun(waitingFor: "the elicitation \(first.elicitationId)") {
            try await context.elicit(first)
        }
        let secondAnswering = AnswerDrivenRun(waitingFor: "the elicitation \(second.elicitationId)") {
            try await context.elicit(second)
        }

        try await Self.waitUntilPending([first.elicitationId, second.elicitationId], in: runPlane)

        // Answer out of order, each by its own id.
        await runPlane.respond(elicitationId: second.elicitationId, .accept(content: ["name": .string("Grace")]))
        await runPlane.respond(elicitationId: first.elicitationId, .decline)

        let firstAnswer = try await firstAnswering.deliveredAnswer()
        let secondAnswer = try await secondAnswering.deliveredAnswer()
        #expect(firstAnswer.action == .decline)
        #expect(firstAnswer.content == nil)
        #expect(secondAnswer.action == .accept)
        #expect(secondAnswer.content == ["name": .string("Grace")])

        // Both requests went to the sink under the correlation of the run.
        let events = await sink.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .elicitation })
        let carried = Set(events.compactMap { $0.elicitation?.elicitationId })
        #expect(carried == [first.elicitationId, second.elicitationId])
    }

    @Test("elicit registers before it posts: an answer that comes when the event is seen is delivered")
    func elicitAnswerArrivingImmediatelyIsDelivered() async throws {
        let runPlane = RunPlane()
        // The sink answers from inside `post(event:)`. When the elicitation
        // were not pending before the post, the answer would do nothing and
        // the elicit would never end.
        let sink = ImmediatelyRespondingSink(runPlane: runPlane, response: .decline)
        let context = Self.makeContext(sink: sink, runPlane: runPlane)

        let request = Self.formRequest()
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await context.elicit(request)
        }
        let answer = try await answering.deliveredAnswer()

        #expect(answer.action == .decline)
        #expect(answer.content == nil)
    }

    @Test("the context of a tool with an empty name stamps its type name; tool and op are never empty")
    func stampingEmptyNamedToolNeverStampsEmpty() async throws {
        let sink = RecordingSink()
        let context = ToolContext(
            calling: EmptyNamedTool(),
            on: MountSite(sessionID: ULID(), runPlane: RunPlane(), sink: sink),
            sink: sink,
            completionToken: RunPlane.makeCompletionToken(),
            state: ToolCallState()
        )

        #expect(context.tool == "EmptyNamedTool")
        #expect(context.op == "EmptyNamedTool")

        await context.progress("still stamped")

        let posted = try #require(await sink.events.first)
        #expect(!posted.tool.isEmpty)
        #expect(!posted.op.isEmpty)
    }

    // MARK: - Attachments

    @Test("attach gives each record to the sink of the context, in call order")
    func attachRoutesToTheBoundSink() {
        let state = ToolCallState()
        let context = ToolContext(
            sessionID: ULID(),
            runPlane: RunPlane(),
            sink: RecordingSink(),
            tool: Self.demoToolName,
            op: Self.demoToolName,
            completionToken: RunPlane.makeCompletionToken(),
            isCancelled: { false },
            attachmentSink: { state.attach($0) }
        )

        context.attach(MountFixtures.firstAttachment)
        context.attach(MountFixtures.secondAttachment)

        #expect(state.drainAttachments() == MountFixtures.attachmentsInCallOrder)
        // A drain empties the records: the same records never go out two times.
        #expect(state.drainAttachments().isEmpty)
    }

    @Test("attach on a context with the default attachment sink drops the record: no event carries it")
    func attachOnTheDefaultSinkDrops() async {
        let sink = RecordingSink()
        let context = Self.makeContext(sink: sink)

        context.attach(MountFixtures.firstAttachment)

        // An attachment is never an event.
        #expect(await sink.events.isEmpty)
    }

    // MARK: - The run plane

    @Test("backgroundRuns() reports the background runs of the session, and a settled run leaves the report")
    func backgroundRunsReportsTheSessionsRuns() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), runPlane: runPlane)
        let token = await FakeRun.start(on: runPlane, latch: latch, detailOnSettle: "exit 0")

        let runs = await context.backgroundRuns()
        #expect(runs.count == 1)
        #expect(runs.first?.completionToken == token)
        #expect(runs.first?.tool == FakeRun.tool)
        #expect(runs.first?.op == FakeRun.op)
        #expect(runs.first?.kind == .swiftTask)
        #expect(runs.first?.latestProgressDetail == nil)

        await runPlane.updateProgress(completionToken: token, detail: "50%")
        #expect(await context.backgroundRuns().first?.latestProgressDetail == "50%")

        latch.open()
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
        #expect(await context.backgroundRuns().isEmpty)
    }

    @Test("wait() gives the terminal event of the run when it settles")
    func waitResolvesToTheTerminalEvent() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), runPlane: runPlane)
        let token = await FakeRun.start(on: runPlane, latch: latch, detailOnSettle: "exit 0")

        latch.open()
        let outcome = await context.wait(completionToken: token, seconds: Self.settlementDeadline)

        let terminal = try #require(outcome.settledTerminal)
        #expect(terminal.correlationID == token)
        #expect(terminal.detail == "exit 0")
        #expect(terminal.outcome == .succeeded)
    }

    @Test("wait() reports that its deadline elapsed, and the run stays tracked")
    func waitReportsTheDeadlineElapsing() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), runPlane: runPlane)
        let token = await FakeRun.start(on: runPlane, latch: latch)

        #expect(await context.wait(completionToken: token, seconds: Self.elapsingDeadline) == .deadlineElapsed)
        #expect(await context.backgroundRuns().count == 1)

        // Settle the fake run, so no wait stays after the test.
        latch.open()
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
    }

    @Test("wait() on a token that names no run reports it and does nothing")
    func waitReportsAnUnknownToken() async throws {
        let context = Self.makeContext(sink: RecordingSink())

        let outcome = await context.wait(
            completionToken: RunPlane.makeCompletionToken(), seconds: Self.settlementDeadline)

        #expect(outcome == .unknownToken)
    }

    @Test("cancel() reports the outcome that the canceler of the run reports")
    func cancelReportsTheCancelersOutcome() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), runPlane: runPlane)
        let token = await FakeRun.start(on: runPlane, latch: latch, cancelerOutcome: .cancelled)

        #expect(await context.cancel(completionToken: token) == .reported(.cancelled))

        // The cancelled run settles later; collect it, so nothing waits after
        // the test.
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
    }

    @Test("cancel() on a run that already settled reports its kept terminal event")
    func cancelReportsAnAlreadySettledRun() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), runPlane: runPlane)
        let token = await FakeRun.start(on: runPlane, latch: latch, detailOnSettle: "exit 0")

        latch.open()
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
        let outcome = await context.cancel(completionToken: token)

        let terminal = try #require(outcome.alreadySettledTerminal)
        #expect(terminal.correlationID == token)
        #expect(terminal.outcome == .succeeded)
    }

    @Test("cancel() on a token that names no run reports it and does nothing")
    func cancelReportsAnUnknownToken() async throws {
        let context = Self.makeContext(sink: RecordingSink())

        let outcome = await context.cancel(completionToken: RunPlane.makeCompletionToken())

        #expect(outcome == .unknownToken)
    }
}
