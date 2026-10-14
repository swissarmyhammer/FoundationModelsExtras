@_spi(Testing) @testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// ``ManualRunClock``: a clock that moves only when the test advances it.
@Suite("ManualRunClock: a clock that a test advances", .timeLimit(.minutes(1)))
struct ManualRunClockTests {
    @Test("an advance ends each wait that it reaches, and keeps each later wait")
    func advanceEndsTheReachedWaits() async throws {
        let clock = ManualRunClock()
        let start = clock.now
        let early = Task { try await clock.sleep(until: start.advanced(by: .seconds(1))) }
        let late = Task { try await clock.sleep(until: start.advanced(by: .seconds(5))) }
        await clock.waitForSleepers(atLeast: 2)

        clock.advance(by: .seconds(2))

        try await early.value
        #expect(clock.sleeperCount == 1)
        #expect(clock.now == start.advanced(by: .seconds(2)))

        clock.advance(by: .seconds(3))

        try await late.value
        #expect(clock.sleeperCount == 0)
    }

    @Test("a wait for a deadline that the clock passed ends at once")
    func pastDeadlineEndsAtOnce() async throws {
        let clock = ManualRunClock()

        try await clock.sleep(until: clock.now)

        #expect(clock.sleeperCount == 0)
    }

    @Test("a negative advance does not move the clock")
    func negativeAdvanceDoesNotMove() {
        let clock = ManualRunClock()
        let start = clock.now

        clock.advance(by: .seconds(-1))

        #expect(clock.now == start)
    }

    @Test("a cancel ends a wait with CancellationError, and removes it")
    func cancelThrowsAndRemovesTheWait() async {
        let clock = ManualRunClock()
        let sleeping = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(1))) }
        await clock.waitForSleepers(atLeast: 1)

        sleeping.cancel()

        await #expect(throws: CancellationError.self) { try await sleeping.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test("the real clock of a run plane is ContinuousRunClock by default")
    func runPlaneDefaultsToTheRealClock() {
        #expect(RunPlane().clock is ContinuousRunClock)
    }
}

/// The timers of a run plane on a ``ManualRunClock``: the deadline of a wait,
/// the timeout of a run, and the settle period of a background call. Each
/// test moves the clock in a fixed order, with no real sleep.
@Suite("RunPlane timers on a ManualRunClock", .timeLimit(.minutes(1)))
struct RunPlaneManualClockTests {
    private typealias Fixtures = MountFixtures

    /// The timeout, in seconds, of the mount in the timeout tests.
    private static let timeoutSeconds: TimeInterval = 10

    /// The settle period, in seconds, of the site in the settle test.
    private static let graceSeconds: TimeInterval = 6

    /// Waits on its gate, posts one progress event, then sleeps until it is
    /// cancelled.
    private struct ProgressThenSleepTool: Tool {
        let name = "progress_then_sleep_tool"
        let description = "posts one progress event when its gate opens, then sleeps"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            await ToolContext.current?.progress("alive")
            try await Task.sleep(for: .seconds(3600))
            return "never returned"
        }
    }

    @Test("a wait with a deadline ends only when the clock reaches the deadline")
    func waitDeadlineFollowsTheClock() async throws {
        let clock = ManualRunClock()
        let runPlane = RunPlane(clock: clock)
        let gate = RunLatch()
        let token = RunPlane.makeCompletionToken()
        await runPlane.start(tool: "t", op: "run test", kind: .swiftTask, completionToken: token, canceler: nil) {
            await gate.waitUntilOpen()
            return OperationEvent(tool: "t", op: "run test", correlationID: token, kind: .completed, detail: "", outcome: .succeeded)
        }
        let waiting = Task { await runPlane.wait(completionToken: token, seconds: 5) }
        await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: .seconds(4))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))

        #expect(await waiting.value == .deadlineElapsed)
        gate.open()
        _ = try await Fixtures.settledTerminal(of: token, in: runPlane)
    }

    @Test("a run with no progress times out when the clock reaches the timeout")
    func runTimeoutFollowsTheClock() async throws {
        let clock = ManualRunClock()
        let sink = Fixtures.RecordingSink()
        let mounted = RunToCompletionRunner(
            wrapping: Fixtures.SleepingTool(), site: Fixtures.site(runPlane: RunPlane(clock: clock), sink: sink),
            timeout: Self.timeoutSeconds)
        let calling = Task { try await mounted.call(arguments: MountArguments(value: "x")) }
        await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: .seconds(Self.timeoutSeconds))

        await #expect(throws: ToolMountError.timedOut(tool: "sleeping_tool", timeoutSeconds: Self.timeoutSeconds)) {
            _ = try await calling.value
        }
        #expect(await sink.events.last?.outcome == .timedOut)
    }

    @Test("progress inside a window starts a new full window of the timeout")
    func progressResetsTheTimeout() async throws {
        let clock = ManualRunClock()
        let gate = RunLatch()
        let sink = Fixtures.RecordingSink()
        let mounted = RunToCompletionRunner(
            wrapping: ProgressThenSleepTool(gate: gate),
            site: Fixtures.site(runPlane: RunPlane(clock: clock), sink: sink), timeout: Self.timeoutSeconds)
        let calling = Task { try await mounted.call(arguments: MountArguments(value: "x")) }
        await clock.waitForSleepers(atLeast: 1)

        // Progress in the middle of the first window.
        clock.advance(by: .seconds(Self.timeoutSeconds / 2))
        gate.open()
        try await AwaitedCondition.wait { await sink.events.contains { $0.detail == "alive" } }

        // The end of the first window finds the progress, and starts a new
        // full window.
        clock.advance(by: .seconds(Self.timeoutSeconds / 2))
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(Self.timeoutSeconds - 1))
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .seconds(1))

        await #expect(
            throws: ToolMountError.timedOut(tool: "progress_then_sleep_tool", timeoutSeconds: Self.timeoutSeconds)
        ) {
            _ = try await calling.value
        }
    }

    @Test("a background call answers with the pending envelope when the clock reaches the end of its settle period")
    func settlePeriodFollowsTheClock() async throws {
        let clock = ManualRunClock()
        let gate = RunLatch()
        let runPlane = RunPlane(clock: clock)
        let mounted = BackgroundToolRunner(
            wrapping: Fixtures.GatedTool(gate: gate),
            site: Fixtures.site(runPlane: runPlane, sink: Fixtures.RecordingSink(), inlineSettleGrace: Self.graceSeconds),
            timeout: nil)
        let calling = Task { try await mounted.call(arguments: MountArguments(value: "x")) }
        await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: .seconds(Self.graceSeconds))

        let envelope = try Fixtures.decodeEnvelope(try await calling.value)
        #expect(envelope.isPending)
        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: runPlane)
        #expect(terminal.detail == "gated: x")
    }
}
