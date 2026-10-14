@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises the link from each open question to the run that asked it, and
/// the list of the open runs that wait only for the user.
@Suite("Run plane: open questions and the runs that wait only for the user", .timeLimit(.minutes(1)))
struct RunPlaneUserWaitTests {
    private typealias Fixtures = MountFixtures

    /// The value of each fixture call.
    private static let callValue = "x"

    /// Waits until `runPlane` has `count` open questions.
    ///
    /// - Parameters:
    ///   - count: The number of open questions.
    ///   - runPlane: The run plane.
    private static func waitForOpenQuestions(_ count: Int, on runPlane: RunPlane) async throws {
        try await AwaitedCondition.wait { await runPlane.openElicitations().count == count }
    }

    /// Asks `elicitationId` on `runPlane` for the run of `runToken`, in a run
    /// that ends when the question gets its answer.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - runToken: The completion token of the run that asks.
    ///   - runPlane: The run plane.
    /// - Returns: The run that waits for the answer.
    private static func ask(
        _ elicitationId: ULID, for runToken: String, on runPlane: RunPlane
    ) -> AnswerDrivenRun<ElicitationResponse> {
        AnswerDrivenRun(waitingFor: "the question \(elicitationId)") {
            await runPlane.awaitAnswer(to: Fixtures.nameRequest(elicitationId: elicitationId), runToken: runToken)
        }
    }

    /// Calls the mounted tool of a background run in a synchronous mount, and
    /// returns its output. The inner tool asks one question.
    private struct MountingElicitTool: Tool {
        let name = "mounting_elicit_tool"
        let description = "mounts a tool that asks one question, and calls it"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let inner = context.mount(MountFixtures.ElicitOnceTool())
            return try await inner.call(arguments: arguments)
        }
    }

    // MARK: - The link of each question

    @Test("openElicitations() lists each open question with the token of the run that asked it, in arrival order")
    func openElicitationsListEachQuestionWithItsRunToken() async throws {
        let runPlane = RunPlane()
        let firstRun = RunPlane.makeCompletionToken()
        let secondRun = RunPlane.makeCompletionToken()
        let firstQuestion = ULID()
        let secondQuestion = ULID()

        let firstAnswer = Self.ask(firstQuestion, for: firstRun, on: runPlane)
        try await Self.waitForOpenQuestions(1, on: runPlane)
        let secondAnswer = Self.ask(secondQuestion, for: secondRun, on: runPlane)
        try await Self.waitForOpenQuestions(2, on: runPlane)

        #expect(
            await runPlane.openElicitations() == [
                OpenElicitation(elicitationId: firstQuestion, runToken: firstRun),
                OpenElicitation(elicitationId: secondQuestion, runToken: secondRun),
            ])

        #expect(await runPlane.respond(elicitationId: firstQuestion, .decline) == .delivered)
        #expect(try await firstAnswer.answerOnceDelivered() == .decline)
        #expect(await runPlane.openElicitations() == [OpenElicitation(elicitationId: secondQuestion, runToken: secondRun)])

        #expect(await runPlane.respond(elicitationId: secondQuestion, .decline) == .delivered)
        #expect(try await secondAnswer.answerOnceDelivered() == .decline)
        #expect(await runPlane.openElicitations().isEmpty)
    }

    // MARK: - The runs that wait only for the user

    @Test("runsWaitingOnlyForUser() lists an open run with an open question, and not an open run with no question")
    func runsWaitingOnlyForUserListsOnlyTheAskingRun() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let askingRun = await FakeRun.start(on: runPlane, latch: latch)
        let workingRun = await FakeRun.start(on: runPlane, latch: latch)
        #expect(await runPlane.runsWaitingOnlyForUser().isEmpty)

        let question = ULID()
        let answer = Self.ask(question, for: askingRun, on: runPlane)
        try await Self.waitForOpenQuestions(1, on: runPlane)

        let waiting = await runPlane.runsWaitingOnlyForUser().map(\.completionToken)
        #expect(waiting == [askingRun])
        #expect(!waiting.contains(workingRun))

        #expect(await runPlane.respond(elicitationId: question, .decline) == .delivered)
        #expect(try await answer.answerOnceDelivered() == .decline)
        #expect(await runPlane.runsWaitingOnlyForUser().isEmpty)

        latch.open()
        _ = await runPlane.wait(completionToken: askingRun, seconds: nil)
        _ = await runPlane.wait(completionToken: workingRun, seconds: nil)
    }

    @Test("a question whose token names no open run lists no run")
    func aQuestionOfNoOpenRunListsNoRun() async throws {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let openRun = await FakeRun.start(on: runPlane, latch: latch)
        let question = ULID()
        let answer = Self.ask(question, for: RunPlane.makeCompletionToken(), on: runPlane)
        try await Self.waitForOpenQuestions(1, on: runPlane)

        #expect(await runPlane.runsWaitingOnlyForUser().isEmpty)

        #expect(await runPlane.respond(elicitationId: question, .decline) == .delivered)
        #expect(try await answer.answerOnceDelivered() == .decline)
        latch.open()
        _ = await runPlane.wait(completionToken: openRun, seconds: nil)
    }

    // MARK: - Questions from tool calls

    @Test("a background call links its question to its own run, and that run waits only for the user")
    func aBackgroundCallLinksItsQuestionToItsRun() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.ElicitOnceTool())
        let rendered = try await harness.mounted.call(arguments: MountArguments(value: Self.callValue))
        let token = try Fixtures.decodeEnvelope(rendered).completionToken
        try await Self.waitForOpenQuestions(1, on: harness.runPlane)

        let question = try #require(await harness.runPlane.openElicitations().first)
        #expect(question.runToken == token)
        #expect(await harness.runPlane.runsWaitingOnlyForUser().map(\.completionToken) == [token])

        #expect(await harness.runPlane.respond(elicitationId: question.elicitationId, .decline) == .delivered)
        let terminal = try #require(await harness.runPlane.wait(completionToken: token, seconds: nil).settledTerminal)
        #expect(terminal.detail == "answered: decline")
        #expect(await harness.runPlane.runsWaitingOnlyForUser().isEmpty)
        #expect(await harness.runPlane.openElicitations().isEmpty)
    }

    @Test("a synchronous call that a background run mounts links its question to the background run")
    func aMountedSynchronousCallLinksItsQuestionToTheHoldingRun() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: MountingElicitTool())
        let rendered = try await harness.mounted.call(arguments: MountArguments(value: Self.callValue))
        let outerToken = try Fixtures.decodeEnvelope(rendered).completionToken
        try await Self.waitForOpenQuestions(1, on: harness.runPlane)

        let question = try #require(await harness.runPlane.openElicitations().first)
        #expect(question.runToken == outerToken)
        #expect(await harness.runPlane.backgroundRuns().map(\.completionToken) == [outerToken])
        #expect(await harness.runPlane.runsWaitingOnlyForUser().map(\.completionToken) == [outerToken])

        #expect(await harness.runPlane.respond(elicitationId: question.elicitationId, .decline) == .delivered)
        let terminal = try #require(await harness.runPlane.wait(completionToken: outerToken, seconds: nil).settledTerminal)
        #expect(terminal.detail == "answered: decline")
        #expect(await harness.runPlane.runsWaitingOnlyForUser().isEmpty)
    }

    @Test("a host context links its question to its own token, and no open run waits only for the user")
    func aHostContextLinksItsQuestionToItsToken() async throws {
        let runPlane = RunPlane()
        let token = RunPlane.makeCompletionToken()
        let context = ToolContext(
            sessionID: ULID(),
            runPlane: runPlane,
            sink: DiscardingOperationEventSink(),
            tool: "host",
            op: "ask user",
            completionToken: token,
            isCancelled: { false }
        )
        let question = ULID()
        let answer = AnswerDrivenRun(waitingFor: "the question of the host context") {
            try await context.elicit(Fixtures.nameRequest(elicitationId: question))
        }
        try await Self.waitForOpenQuestions(1, on: runPlane)

        #expect(await runPlane.openElicitations() == [OpenElicitation(elicitationId: question, runToken: token)])
        #expect(await runPlane.runsWaitingOnlyForUser().isEmpty)

        #expect(await runPlane.respond(elicitationId: question, .decline) == .delivered)
        #expect(try await answer.answerOnceDelivered() == .decline)
    }
}
