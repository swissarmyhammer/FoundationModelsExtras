import FoundationModelsExtras
import Testing
import ULID

/// ``ModelCallMark``: the mark of one model call, which a session reads to
/// refuse a wait for its own answer inside its own open call, and which
/// ``GenerationQueue`` reads to refuse a submission inside an open submission
/// on itself. The refusal of the queue is tested in
/// `GenerationQueueWorkerTests`; these tests hold the session half.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees.
@Suite("ModelCallMark")
struct ModelCallMarkTests {
    /// The model the marks of these tests name.
    private static let markedModel: ModelRef = "org/marked-model"

    @Test("an open mark is the open model call of its own session only")
    func anOpenMarkIsTheOpenCallOfItsOwnSession() {
        let session = ULID()
        let otherSession = ULID()
        let mark = ModelCallMark(sessionID: session)

        #expect(mark.sessionID == session)
        #expect(mark.submission == nil)
        #expect(mark.isOpenModelCall(of: session))
        #expect(!mark.isOpenModelCall(of: otherSession))
    }

    @Test("a closed mark is no open model call, and names no open submission")
    func aClosedMarkIsNoOpenCall() {
        let session = ULID()
        let queue = GenerationQueue()
        let mark = ModelCallMark(sessionID: session, submission: SubmissionTarget(queue: queue, model: Self.markedModel))
        let openTarget = mark.openSubmission(on: queue)

        mark.close()

        #expect(openTarget?.model == Self.markedModel)
        #expect(openTarget?.queue === queue)
        #expect(!mark.isOpenModelCall(of: session))
        #expect(mark.openSubmission(on: queue) == nil)
    }

    @Test("an open mark names no open submission on another queue")
    func anOpenMarkNamesNoSubmissionOnAnotherQueue() {
        let mark = ModelCallMark(
            sessionID: ULID(), submission: SubmissionTarget(queue: GenerationQueue(), model: Self.markedModel))

        #expect(mark.openSubmission(on: GenerationQueue()) == nil)
    }

    @Test("a background run keeps the session and the submission of the call, under a closed mark")
    func aBackgroundRunGetsAClosedMarkOfTheSameSession() async {
        let session = ULID()
        let queue = GenerationQueue()
        let open = ModelCallMark(sessionID: session, submission: SubmissionTarget(queue: queue, model: Self.markedModel))

        let background = await ModelCallMark.$current.withValue(open) {
            await ModelCallMark.withBackgroundRunMark { ModelCallMark.current }
        }

        #expect(background !== open)
        #expect(background?.sessionID == session)
        #expect(background?.submission?.queue === queue)
        #expect(background?.isOpenModelCall(of: session) == false)
        #expect(open.isOpenModelCall(of: session))
    }

    @Test("a background run outside any model call runs with no mark")
    func aBackgroundRunOutsideAnyCallHasNoMark() async {
        let mark = await ModelCallMark.withBackgroundRunMark { ModelCallMark.current }

        #expect(mark == nil)
    }
}
