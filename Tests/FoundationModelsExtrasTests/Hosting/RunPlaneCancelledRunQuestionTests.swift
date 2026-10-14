@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the end of the open questions of a run that a cancel or the
/// sweep stops: each question of that run gets a cancel with
/// ``RunPlane/runCancelledReason``, before the run plane waits for the
/// canceler. The questions of other runs stay open.
@Suite("Run plane: the questions of a cancelled run end with the reason \"run cancelled\"", .timeLimit(.minutes(1)))
struct RunPlaneCancelledRunQuestionTests {
    private typealias Fixtures = MountFixtures

    /// The value of each fixture call.
    private static let callValue = "x"

    /// A background run whose body asks one question and waits in
    /// `awaitAnswer`. Its canceler waits until the body got its answer, as a
    /// process canceler waits until its process exits. Thus a cancel that
    /// waits for the canceler before it ends the question never returns.
    private struct AskingRun {
        /// The completion token of the run.
        let token: String

        /// The id of the question of the run.
        let elicitationId: ULID

        /// Gets the answer that the body of the run got.
        let answer: Promise<ElicitationResponse>

        /// Starts an asking run on `runPlane`, and returns when its question
        /// is open.
        ///
        /// - Parameter runPlane: The run plane that tracks the run.
        /// - Returns: The run.
        static func start(on runPlane: RunPlane) async -> AskingRun {
            let token = RunPlane.makeCompletionToken()
            let elicitationId = ULID()
            let answer = Promise<ElicitationResponse>()
            let posted = RunLatch()
            await runPlane.start(
                tool: FakeRun.tool,
                op: FakeRun.op,
                kind: .process,
                completionToken: token,
                canceler: {
                    _ = await answer.value
                    return .stopped
                },
                body: {
                    let response = await runPlane.awaitAnswer(
                        to: Fixtures.nameRequest(elicitationId: elicitationId), runToken: token
                    ) { posted.open() }
                    answer.fulfill(response)
                    return FakeRun.terminalEvent(token: token, outcome: .cancelled, detail: response.reason ?? "")
                }
            )
            await posted.waitUntilOpen()
            return AskingRun(token: token, elicitationId: elicitationId, answer: answer)
        }

        /// The question of this run, as ``RunPlane/openElicitations()`` lists
        /// it.
        var openElicitation: OpenElicitation {
            OpenElicitation(elicitationId: elicitationId, runToken: token)
        }
    }

    /// Cancels the run of `token` on `runPlane`, in a run that a broken
    /// cancel cannot hang.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - runPlane: The run plane.
    /// - Returns: The cancel, which ends when the run plane reports.
    private static func cancelling(_ token: String, on runPlane: RunPlane) -> AnswerDrivenRun<CancelOutcome> {
        AnswerDrivenRun(waitingFor: "the cancel of the run \(token)") {
            await runPlane.cancel(completionToken: token)
        }
    }

    // MARK: - cancel(completionToken:)

    @Test("cancel(completionToken:) ends the question of the run with cancel and the reason, before it waits for the canceler")
    func cancelEndsTheQuestionOfTheRunBeforeTheCanceler() async throws {
        let runPlane = RunPlane()
        let run = await AskingRun.start(on: runPlane)

        let outcome = try await Self.cancelling(run.token, on: runPlane).deliveredAnswer()

        #expect(outcome == .reported(.stopped))
        #expect(await run.answer.value == .cancel(reason: RunPlane.runCancelledReason))
        #expect(await runPlane.openElicitations().isEmpty)
    }

    @Test("cancel(completionToken:) leaves the question of a different run open")
    func cancelLeavesTheQuestionOfADifferentRunOpen() async throws {
        let runPlane = RunPlane()
        let cancelled = await AskingRun.start(on: runPlane)
        let other = await AskingRun.start(on: runPlane)

        _ = try await Self.cancelling(cancelled.token, on: runPlane).deliveredAnswer()

        #expect(await runPlane.openElicitations() == [other.openElicitation])
        #expect(await runPlane.respond(elicitationId: other.elicitationId, .decline) == .delivered)
        #expect(await other.answer.value == .decline)
    }

    @Test("cancel(completionToken:) of a background run ends the question of a synchronous call that the run mounted")
    func cancelEndsTheQuestionOfAMountedSynchronousCall() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.MountingElicitTool())
        let rendered = try await harness.mounted.call(arguments: MountArguments(value: Self.callValue))
        let outerToken = try Fixtures.decodeEnvelope(rendered).completionToken
        _ = try await Fixtures.firstPendingElicitationId(in: harness.runPlane)

        _ = try await Self.cancelling(outerToken, on: harness.runPlane).deliveredAnswer()

        #expect(await harness.runPlane.openElicitations().isEmpty)
        _ = try await Fixtures.settledTerminal(of: outerToken, in: harness.runPlane)
    }

    // MARK: - sweep()

    @Test("sweep() ends the question of a run with cancel and the reason, before it waits for the canceler")
    func sweepEndsTheQuestionOfTheRunBeforeTheCanceler() async throws {
        let runPlane = RunPlane()
        let run = await AskingRun.start(on: runPlane)

        let sweeping = AnswerDrivenRun(waitingFor: "the sweep of the run \(run.token)") { await runPlane.sweep() }
        let terminals = try await sweeping.deliveredAnswer()

        #expect(terminals.map(\.correlationID) == [run.token])
        #expect(await run.answer.value == .cancel(reason: RunPlane.runCancelledReason))
        #expect(await runPlane.openElicitations().isEmpty)
    }
}
