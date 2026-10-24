import FoundationModelsExtras
import Synchronization
import Testing

/// Holds ``GenerationQueue`` to the access level a consumer outside this
/// package needs: a consumer makes its own queue and submits each scripted
/// call in `submit`, so its queue behavior is testable without MLX.
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

    @Test("the README example: one job runs, and it does not wait")
    func readmeWorkQueueExample() async throws {
        let waits = Atomic<Int>(0)

        // README example: begin
        let queue = GenerationQueue()

        // One worker runs the jobs one at a time, first in first out. `onQueued`
        // runs only when the job must wait behind another job.
        let answer = try await queue.submit(onQueued: { waits.add(1, ordering: .relaxed) }) {
            "the answer of one job"
        }
        // README example: end

        #expect(answer == "the answer of one job")
        #expect(waits.load(ordering: .relaxed) == 0)
    }
}
