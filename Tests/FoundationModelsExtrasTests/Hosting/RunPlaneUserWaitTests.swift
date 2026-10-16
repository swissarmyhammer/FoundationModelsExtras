@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises the link from each open question to the run that asked it, and
/// the list of the open runs that wait only for the user.
///
/// No test waits for an event that a broken run plane does not give: each
/// wait for a question also ends when the asker or the run ends, and each
/// question that is still open at the end gets an end from the test.
@Suite("Run plane: open questions and the runs that wait only for the user")
struct RunPlaneUserWaitTests {
    private typealias Fixtures = MountFixtures

    /// The value of each fixture call.
    private static let callValue = "x"

    /// Asks `elicitationId` on `runPlane` for the run of `runToken`. Returns
    /// when the run plane posted the question, or when the asker got an
    /// answer first.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - runToken: The completion token of the run that asks.
    ///   - runPlane: The run plane.
    /// - Returns: The task that waits for the answer.
    private static func ask(
        _ elicitationId: ULID, for runToken: String, on runPlane: RunPlane
    ) async -> QuestionTask<ElicitationResponse> {
        await QuestionTask.ask(Fixtures.nameRequest(elicitationId: elicitationId), runToken: runToken, on: runPlane)
    }

    /// Starts one call of `tool` in a background harness, and waits until
    /// the sink of the harness got the question of the run, or until the
    /// run settled first.
    ///
    /// - Parameters:
    ///   - tool: The tool. It asks one question in its run.
    ///   - arguments: The arguments of the call.
    /// - Returns: The harness, and the completion token of the run.
    /// - Throws: When the call fails, or when no question came.
    private static func startAskingCall<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        _ tool: any Tool<Arguments, String>, arguments: Arguments
    ) async throws -> (harness: Fixtures.Harness<BackgroundToolRunner<Arguments>>, token: String) {
        let harness = Fixtures.backgroundHarness(wrapping: tool)
        let rendered = try await harness.mounted.call(arguments: arguments)
        let token = try Fixtures.decodeEnvelope(rendered).completionToken
        _ = try await Fixtures.firstQuestionId(postedTo: harness.sink, byRun: token, on: harness.runPlane)
        return (harness, token)
    }

    // MARK: - The link of each question

    @Test("openElicitations() lists each open question with the token of the run that asked it, in arrival order")
    func openElicitationsListEachQuestionWithItsRunToken() async throws {
        let runPlane = RunPlane()
        let firstRun = RunPlane.makeCompletionToken()
        let secondRun = RunPlane.makeCompletionToken()
        let firstQuestion = ULID()
        let secondQuestion = ULID()

        let firstAnswer = await Self.ask(firstQuestion, for: firstRun, on: runPlane)
        let secondAnswer = await Self.ask(secondQuestion, for: secondRun, on: runPlane)

        #expect(
            await runPlane.openElicitations() == [
                OpenElicitation(elicitationId: firstQuestion, runToken: firstRun),
                OpenElicitation(elicitationId: secondQuestion, runToken: secondRun),
            ])

        #expect(await runPlane.respond(elicitationId: firstQuestion, .decline) == .delivered)
        #expect(try await firstAnswer.answer(on: runPlane) == .decline)
        #expect(await runPlane.openElicitations() == [OpenElicitation(elicitationId: secondQuestion, runToken: secondRun)])

        #expect(await runPlane.respond(elicitationId: secondQuestion, .decline) == .delivered)
        #expect(try await secondAnswer.answer(on: runPlane) == .decline)
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
        let answer = await Self.ask(question, for: askingRun, on: runPlane)

        let waiting = await runPlane.runsWaitingOnlyForUser().map(\.completionToken)
        #expect(waiting == [askingRun])
        #expect(!waiting.contains(workingRun))

        #expect(await runPlane.respond(elicitationId: question, .decline) == .delivered)
        #expect(try await answer.answer(on: runPlane) == .decline)
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
        let answer = await Self.ask(question, for: RunPlane.makeCompletionToken(), on: runPlane)
        #expect(await runPlane.openElicitations().map(\.elicitationId) == [question])

        #expect(await runPlane.runsWaitingOnlyForUser().isEmpty)

        #expect(await runPlane.respond(elicitationId: question, .decline) == .delivered)
        #expect(try await answer.answer(on: runPlane) == .decline)
        latch.open()
        _ = await runPlane.wait(completionToken: openRun, seconds: nil)
    }

    // MARK: - Questions from tool calls

    @Test("a background call links its question to its own run, and that run waits only for the user")
    func aBackgroundCallLinksItsQuestionToItsRun() async throws {
        let (harness, token) = try await Self.startAskingCall(
            Fixtures.ElicitOnceTool(), arguments: MountArguments(value: Self.callValue))

        let question = try #require(await harness.runPlane.openElicitations().first)
        #expect(question.runToken == token)
        #expect(await harness.runPlane.runsWaitingOnlyForUser().map(\.completionToken) == [token])

        #expect(await harness.runPlane.respond(elicitationId: question.elicitationId, .decline) == .delivered)
        await OpenQuestions.endIfOpen(question.elicitationId, on: harness.runPlane)
        let terminal = try #require(await harness.runPlane.wait(completionToken: token, seconds: nil).settledTerminal)
        #expect(terminal.detail == "answered: decline")
        #expect(await harness.runPlane.runsWaitingOnlyForUser().isEmpty)
        #expect(await harness.runPlane.openElicitations().isEmpty)
    }

    @Test("a synchronous call that a background run mounts links its question to the background run")
    func aMountedSynchronousCallLinksItsQuestionToTheHoldingRun() async throws {
        let (harness, outerToken) = try await Self.startAskingCall(
            Fixtures.MountingElicitTool(), arguments: MountArguments(value: Self.callValue))

        let question = try #require(await harness.runPlane.openElicitations().first)
        #expect(question.runToken == outerToken)
        #expect(await harness.runPlane.backgroundRuns().map(\.completionToken) == [outerToken])
        #expect(await harness.runPlane.runsWaitingOnlyForUser().map(\.completionToken) == [outerToken])

        #expect(await harness.runPlane.respond(elicitationId: question.elicitationId, .decline) == .delivered)
        await OpenQuestions.endIfOpen(question.elicitationId, on: harness.runPlane)
        let terminal = try #require(await harness.runPlane.wait(completionToken: outerToken, seconds: nil).settledTerminal)
        #expect(terminal.detail == "answered: decline")
        #expect(await harness.runPlane.runsWaitingOnlyForUser().isEmpty)
    }

    @Test("a host context links its question to its own token, and no open run waits only for the user")
    func aHostContextLinksItsQuestionToItsToken() async throws {
        let runPlane = RunPlane()
        let sink = Fixtures.RecordingSink()
        let token = RunPlane.makeCompletionToken()
        let context = Fixtures.hostContext(on: runPlane, sink: sink, completionToken: token)
        let question = ULID()
        let request = Fixtures.nameRequest(elicitationId: question)
        let answer = QuestionTask(asking: question) { try await context.elicit(request) }
        await answer.waitUntilAsked { await sink.waitForAnEvent { $0.elicitation?.elicitationId == question } }

        #expect(await runPlane.openElicitations() == [OpenElicitation(elicitationId: question, runToken: token)])
        #expect(await runPlane.runsWaitingOnlyForUser().isEmpty)

        #expect(await runPlane.respond(elicitationId: question, .decline) == .delivered)
        #expect(try await answer.answer(on: runPlane) == .decline)
    }
}
