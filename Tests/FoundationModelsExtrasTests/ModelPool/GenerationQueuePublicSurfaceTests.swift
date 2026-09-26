import FoundationModelsExtras
import Synchronization
import Testing
import ULID

/// Holds ``GenerationQueue`` to the access level a consumer outside this
/// package needs: a consumer makes its own queue and submits each scripted
/// call in `submit`, so its queue behavior is testable without MLX. A wait
/// that can never end is refused with ``GenerationQueueError``.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("GenerationQueue surface over a plain import")
struct GenerationQueuePublicSurfaceTests {
    /// Counts the items inside the queue at one time, and keeps the largest
    /// count.
    private actor PassCounter {
        /// The passes inside the queue now.
        private var active = 0

        /// The largest number of passes that were inside at one time.
        private(set) var peak = 0

        /// How many passes entered over the whole run.
        private(set) var entered = 0

        /// Records one pass that enters.
        func enter() {
            active += 1
            entered += 1
            peak = max(peak, active)
        }

        /// Records one pass that leaves.
        func exit() {
            active -= 1
        }
    }

    /// How many times each pass yields while it holds the place, so a pass
    /// that did not wait would enter while the other is inside.
    private static let yieldsInsideThePass = 1_000

    /// One scripted pass: it enters, yields while it holds the place, leaves,
    /// and returns `name`.
    ///
    /// - Parameters:
    ///   - name: The answer of the pass.
    ///   - counter: The counter the pass reports to.
    /// - Returns: `name`.
    private static func scriptedPass(named name: String, reportingTo counter: PassCounter) async -> String {
        await counter.enter()
        for _ in 0..<yieldsInsideThePass {
            await Task.yield()
        }
        await counter.exit()
        return name
    }

    @Test("two scripted items on one queue never overlap, and each returns its body's value")
    func scriptedPassesOnOneQueueNeverOverlap() async throws {
        let queue = GenerationQueue()
        let counter = PassCounter()

        async let first = queue.submit { await Self.scriptedPass(named: "first", reportingTo: counter) }
        async let second = queue.submit { await Self.scriptedPass(named: "second", reportingTo: counter) }

        let answers = try await [first, second]
        #expect(answers == ["first", "second"])
        #expect(await counter.entered == 2)
        #expect(await counter.peak == 1)
    }

    /// The label a consumer shows for `error`, or `nil` for an error that is
    /// not a refused wait.
    ///
    /// - Parameter error: The error a call threw.
    /// - Returns: The label, which names the model.
    private static func refusalLabel(for error: any Error) -> String? {
        guard case .waitInsideOpenSubmission(let model) = error as? GenerationQueueError else { return nil }
        return "a tool waited inside its submission on \(model.stringValue)"
    }

    @Test("a consumer matches the refusal of a wait inside an open submission, and reads its model")
    func aConsumerMatchesTheRefusedWait() {
        let model: ModelRef = "org/refused"
        let refusal = GenerationQueueError.waitInsideOpenSubmission(model: model)

        #expect(Self.refusalLabel(for: refusal) == "a tool waited inside its submission on org/refused")
        #expect(refusal.errorDescription?.contains(model.stringValue) == true)
    }

    @Test("the README example: one item runs, then a wait inside an open submission is refused")
    func readmeWorkQueueExample() async throws {
        let waits = Atomic<Int>(0)
        var refusedModel: ModelRef?

        // README example: begin
        let model: ModelRef = "mlx-community/Qwen3-8B-4bit"
        let queue = GenerationQueue()

        // Each call to the model is one item. One worker runs the items one at
        // a time, first in first out. `onQueued` runs only when the item must
        // wait behind another item.
        let answer = try await queue.submit(onQueued: { waits.add(1, ordering: .relaxed) }) {
            "an answer from \(model.stringValue)"
        }

        // A tool body inside an open submission must not wait for the same
        // queue: that submission runs only after the tool body ends. The
        // owner of the call binds a mark, and the queue refuses the wait.
        let mark = ModelCallMark(
            sessionID: ULID(), submission: SubmissionTarget(queue: queue, model: model))
        do {
            _ = try await ModelCallMark.$current.withValue(mark) {
                try await queue.submit { "this item never runs" }
            }
        } catch GenerationQueueError.waitInsideOpenSubmission(let refused) {
            refusedModel = refused
        }
        mark.close()
        // README example: end

        #expect(answer == "an answer from mlx-community/Qwen3-8B-4bit")
        #expect(waits.load(ordering: .relaxed) == 0)
        #expect(refusedModel == model)
    }
}
