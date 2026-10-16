@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the questions of a cancelled token: a question that the token
/// asks after the cancel ends at once, and a cancel ends the open questions of
/// a settled or unknown token too.
///
/// No test waits for an event that a broken run plane does not give: each
/// wait also ends on the event of the old behavior, and the test then ends
/// each open question.
@Suite("Run plane: a cancelled token asks no new question, and a cancel ends the questions of each token")
struct RunPlaneCancelledTokenTests {
    private typealias Fixtures = MountFixtures

    /// What came first for a question: the answer to its asker, or the post
    /// of its elicitation event.
    private enum FirstResult: Equatable {
        /// The asker got this answer, and no post came first.
        case answered(ElicitationResponse)

        /// The question opened, and the run plane posted it.
        case posted
    }

    /// The answer of a question that the run plane ends with a run cancel.
    private static let runCancelled = ElicitationResponse.cancel(reason: RunPlane.runCancelledReason)

    /// Asks one question for `token` on `runPlane`, and tells what came first.
    ///
    /// When the question opened, this function ends it with
    /// ``RunPlane/cancelOpenElicitations()``, so no task waits after the test.
    ///
    /// - Parameters:
    ///   - token: The completion token that asks.
    ///   - runPlane: The run plane.
    /// - Returns: The ``FirstResult``.
    private static func firstResult(ofQuestionFor token: String, on runPlane: RunPlane) async -> FirstResult {
        let first = Promise<FirstResult>()
        let asking = Task {
            let answer = await runPlane.awaitAnswer(to: Fixtures.nameRequest(), runToken: token) {
                first.fulfill(.posted)
            }
            first.fulfill(.answered(answer))
        }
        let result = await first.value
        if result == .posted {
            _ = await runPlane.cancelOpenElicitations()
        }
        await asking.value
        return result
    }

    /// Opens one question for `token` on `runPlane`.
    ///
    /// The function returns when the run plane posted the question, or when
    /// the asker got an answer first. Thus the wait also ends when the
    /// question does not open.
    ///
    /// - Parameters:
    ///   - token: The completion token that asks.
    ///   - runPlane: The run plane.
    /// - Returns: The task of the asker, which ends with its answer.
    private static func openQuestion(for token: String, on runPlane: RunPlane) async -> Task<ElicitationResponse, Never> {
        let postedOrAnswered = RunLatch()
        let asking = Task {
            let answer = await runPlane.awaitAnswer(to: Fixtures.nameRequest(), runToken: token) {
                postedOrAnswered.open()
            }
            postedOrAnswered.open()
            return answer
        }
        await postedOrAnswered.waitUntilOpen()
        return asking
    }

    /// Expects that no question is open on `runPlane`, and then ends each
    /// open question, so that no asker waits after the test.
    ///
    /// - Parameter runPlane: The run plane.
    private static func expectNoOpenQuestion(on runPlane: RunPlane) async {
        let open = await runPlane.openElicitations()
        #expect(open.isEmpty)
        if !open.isEmpty {
            _ = await runPlane.cancelOpenElicitations()
        }
    }

    // MARK: - A question after the cancel

    @Test("after cancel(completionToken:) of an open run, a new question of the run ends at once with cancel and the reason")
    func aQuestionAfterTheCancelOfAnOpenRunEndsAtOnce() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch, kind: .process, cancelerOutcome: .stopped)
        #expect(await runPlane.cancel(completionToken: token) == .reported(.stopped))

        let result = await Self.firstResult(ofQuestionFor: token, on: runPlane)

        #expect(result == .answered(Self.runCancelled))
        #expect(await runPlane.openElicitations().isEmpty)
        #expect(await runPlane.backgroundRuns().map(\.completionToken) == [token])
        latch.open()
    }

    @Test("after cancel(completionToken:) of an unknown token, a new question of the token ends at once")
    func aQuestionAfterTheCancelOfAnUnknownTokenEndsAtOnce() async {
        let runPlane = RunPlane()
        let token = RunPlane.makeCompletionToken()
        #expect(await runPlane.cancel(completionToken: token) == .unknownToken)

        let result = await Self.firstResult(ofQuestionFor: token, on: runPlane)

        #expect(result == .answered(Self.runCancelled))
    }

    @Test("after sweep(), a new question of a swept run ends at once with cancel and the reason")
    func aQuestionAfterTheSweepEndsAtOnce() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        let token = await FakeRun.start(on: runPlane, latch: latch, kind: .process, cancelerOutcome: .stopped)
        #expect(await runPlane.sweep().map(\.correlationID) == [token])

        let result = await Self.firstResult(ofQuestionFor: token, on: runPlane)

        #expect(result == .answered(Self.runCancelled))
        latch.open()
    }

    @Test("a cancel of one token does not end a new question of a different token")
    func aCancelDoesNotEndANewQuestionOfADifferentToken() async {
        let runPlane = RunPlane()
        #expect(await runPlane.cancel(completionToken: RunPlane.makeCompletionToken()) == .unknownToken)

        let result = await Self.firstResult(ofQuestionFor: RunPlane.makeCompletionToken(), on: runPlane)

        #expect(result == .posted)
    }

    // MARK: - The open questions of a closed token

    @Test("cancel(completionToken:) of an unknown token ends its open question with cancel and the reason")
    func aCancelOfAnUnknownTokenEndsItsOpenQuestion() async {
        let runPlane = RunPlane()
        let token = RunPlane.makeCompletionToken()
        let asking = await Self.openQuestion(for: token, on: runPlane)

        let outcome = await runPlane.cancel(completionToken: token)

        #expect(outcome == .unknownToken)
        await Self.expectNoOpenQuestion(on: runPlane)
        #expect(await asking.value == Self.runCancelled)
    }

    @Test("cancel(completionToken:) of a settled token ends its open question with cancel and the reason")
    func aCancelOfASettledTokenEndsItsOpenQuestion() async {
        let runPlane = RunPlane()
        let latch = RunLatch()
        latch.open()
        let token = await FakeRun.start(on: runPlane, latch: latch)
        let settled = await runPlane.wait(completionToken: token, seconds: nil).settledTerminal
        let asking = await Self.openQuestion(for: token, on: runPlane)

        let outcome = await runPlane.cancel(completionToken: token)

        #expect(settled != nil)
        #expect(outcome.alreadySettledTerminal == settled)
        await Self.expectNoOpenQuestion(on: runPlane)
        #expect(await asking.value == Self.runCancelled)
    }
}
