@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the end of the open questions of a run that a cancel or the
/// sweep stops: each question of that run gets a cancel with
/// ``RunPlane/runCancelledReason``, before the run plane waits for the
/// canceler. The questions of other runs stay open.
///
/// No test waits for an event that a broken run plane does not give. The
/// canceler of each asking run records the question when it is still open,
/// and then returns at once, so a cancel that waits for the canceler before
/// it ends the question still returns, and the test fails.
@Suite("Run plane: the questions of a cancelled run end with the reason \"run cancelled\"")
struct RunPlaneCancelledRunQuestionTests {
    private typealias Fixtures = MountFixtures

    /// The value of each fixture call.
    private static let callValue = "x"

    /// A background run whose body asks one question and waits in
    /// `awaitAnswer`. Its canceler waits until the body got its answer, as a
    /// process canceler waits until its process exits.
    ///
    /// When the question is still open at the start of the canceler, the
    /// canceler records it in ``openAtCancel`` and returns at once. Thus a
    /// cancel that waits for the canceler before it ends the question still
    /// returns, and the test reads the record.
    private struct AskingRun {
        /// The completion token of the run.
        let token: String

        /// The id of the question of the run.
        let elicitationId: ULID

        /// Gets the answer that the body of the run got.
        let answer: Promise<ElicitationResponse>

        /// Gets the id of the question when it is still open at the start of
        /// the canceler.
        let openAtCancel: Recorder<ULID>

        /// Starts an asking run on `runPlane`, and returns when its question
        /// is open, or when the run got an answer first.
        ///
        /// - Parameter runPlane: The run plane that tracks the run.
        /// - Returns: The run.
        static func start(on runPlane: RunPlane) async -> AskingRun {
            let token = RunPlane.makeCompletionToken()
            let elicitationId = ULID()
            let answer = Promise<ElicitationResponse>()
            let openAtCancel = Recorder<ULID>()
            let postedOrAnswered = RunLatch()
            await runPlane.start(
                tool: FakeRun.tool,
                op: FakeRun.op,
                kind: .process,
                completionToken: token,
                canceler: {
                    let open = await runPlane.openElicitations().map(\.elicitationId)
                    if open.contains(elicitationId) {
                        openAtCancel.append(elicitationId)
                        return .stopped
                    }
                    _ = await answer.value
                    return .stopped
                },
                body: {
                    let response = await runPlane.awaitAnswer(
                        to: Fixtures.nameRequest(elicitationId: elicitationId), runToken: token
                    ) { postedOrAnswered.open() }
                    answer.fulfill(response)
                    postedOrAnswered.open()
                    return FakeRun.terminalEvent(token: token, outcome: .cancelled, detail: response.reason ?? "")
                }
            )
            await postedOrAnswered.waitUntilOpen()
            return AskingRun(token: token, elicitationId: elicitationId, answer: answer, openAtCancel: openAtCancel)
        }

        /// The question of this run, as ``RunPlane/openElicitations()`` lists
        /// it.
        var openElicitation: OpenElicitation {
            OpenElicitation(elicitationId: elicitationId, runToken: token)
        }
    }

    // MARK: - cancel(completionToken:)

    @Test("cancel(completionToken:) ends the question of the run with cancel and the reason, before it waits for the canceler")
    func cancelEndsTheQuestionOfTheRunBeforeTheCanceler() async {
        let runPlane = RunPlane()
        let run = await AskingRun.start(on: runPlane)

        let outcome = await runPlane.cancel(completionToken: run.token)

        #expect(run.openAtCancel.values.isEmpty)
        #expect(outcome == .reported(.stopped))
        await OpenQuestions.endIfOpen(run.elicitationId, on: runPlane)
        #expect(await run.answer.value == .cancel(reason: RunPlane.runCancelledReason))
        #expect(await runPlane.openElicitations().isEmpty)
    }

    @Test("cancel(completionToken:) leaves the question of a different run open")
    func cancelLeavesTheQuestionOfADifferentRunOpen() async {
        let runPlane = RunPlane()
        let cancelled = await AskingRun.start(on: runPlane)
        let other = await AskingRun.start(on: runPlane)

        _ = await runPlane.cancel(completionToken: cancelled.token)

        #expect(cancelled.openAtCancel.values.isEmpty)
        #expect(await runPlane.openElicitations() == [other.openElicitation])
        #expect(await runPlane.respond(elicitationId: other.elicitationId, .decline) == .delivered)
        await OpenQuestions.endIfOpen(other.elicitationId, on: runPlane)
        #expect(await other.answer.value == .decline)
    }

    @Test("cancel(completionToken:) of a background run ends the question of a synchronous call that the run mounted")
    func cancelEndsTheQuestionOfAMountedSynchronousCall() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.MountingElicitTool())
        let rendered = try await harness.mounted.call(arguments: MountArguments(value: Self.callValue))
        let outerToken = try Fixtures.decodeEnvelope(rendered).completionToken
        _ = try await Fixtures.firstQuestionId(postedTo: harness.sink, byRun: outerToken, on: harness.runPlane)

        _ = await harness.runPlane.cancel(completionToken: outerToken)

        #expect(await harness.runPlane.openElicitations().isEmpty)
        _ = try await Fixtures.settledTerminal(of: outerToken, in: harness.runPlane)
    }

    // MARK: - sweep()

    @Test("sweep() ends the question of a run with cancel and the reason, before it waits for the canceler")
    func sweepEndsTheQuestionOfTheRunBeforeTheCanceler() async {
        let runPlane = RunPlane()
        let run = await AskingRun.start(on: runPlane)

        let terminals = await runPlane.sweep()

        #expect(run.openAtCancel.values.isEmpty)
        #expect(terminals.map(\.correlationID) == [run.token])
        await OpenQuestions.endIfOpen(run.elicitationId, on: runPlane)
        #expect(await run.answer.value == .cancel(reason: RunPlane.runCancelledReason))
        #expect(await runPlane.openElicitations().isEmpty)
    }
}
