@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// Exercises the stop of one call: ``ToolCallState/stop(using:)``,
/// ``ToolRun/stop(using:)``, and the cancel and the sweep of a
/// ``RunKind/process`` background run, which go through them.
///
/// The first stop starts the canceler in a task and keeps that task. A second
/// stop gets the same task, so the canceler runs one time only, and each stop
/// reports the outcome of the first canceler.
@Suite("Tool run stop: a second stop gets the task of the first stop and runs no canceler again")
struct ToolRunStopTests {
    // MARK: - Canceler names

    /// The name that the first canceler records when it runs.
    private static let firstCancelerName = "first canceler"

    /// The name that the second canceler records when it runs.
    private static let secondCancelerName = "second canceler"

    // MARK: - Cancelers

    /// A canceler that records `name` in `calls` each time it runs, and
    /// reports `outcome`.
    ///
    /// - Parameters:
    ///   - name: The name that the canceler records.
    ///   - calls: Gets `name` each time the canceler runs.
    ///   - outcome: The outcome that the canceler reports.
    /// - Returns: The canceler.
    private static func recordingCanceler(
        named name: String,
        into calls: Recorder<String>,
        reporting outcome: OperationOutcome
    ) -> @Sendable () async -> OperationOutcome {
        {
            calls.append(name)
            return outcome
        }
    }

    // MARK: - Routes

    /// A canceler that a stop can run.
    typealias Canceler = @Sendable () async -> OperationOutcome

    /// The two stops of one call, and the end of the call.
    private struct TwoStops {
        /// The first stop. It gets the canceler to run, and reports the
        /// outcome, or `nil` when the stop reported no outcome.
        let first: @Sendable (@escaping Canceler) async -> OperationOutcome?

        /// The second stop, with the same shape as ``first``.
        let second: @Sendable (@escaping Canceler) async -> OperationOutcome?

        /// Lets the work of the call end.
        let finish: @Sendable () -> Void
    }

    /// A route to stop one call two times.
    enum StopRoute: String, CaseIterable, CustomTestStringConvertible {
        /// ``ToolCallState/stop(using:)`` two times.
        case callState

        /// ``ToolRun/stop(using:)`` two times.
        case toolRun

        /// Two cancels of one open ``RunKind/process`` background run.
        case processRunCancelTwice

        /// A cancel and then a sweep of one open ``RunKind/process``
        /// background run.
        case processRunCancelThenSweep

        var testDescription: String { rawValue }
    }

    /// The two stops of one new call through `route`. A process run takes
    /// `processCanceler` as the canceler of its tool, so each of its stops
    /// ignores the canceler that it gets.
    private static func twoStops(through route: StopRoute, processCanceler: @escaping Canceler) async throws -> TwoStops {
        switch route {
        case .callState:
            let state = ToolCallState()
            let stop: @Sendable (@escaping Canceler) async -> OperationOutcome? = { await state.stop(using: $0).value }
            return TwoStops(first: stop, second: stop, finish: {})
        case .toolRun:
            let run = MountFixtures.toolRun(
                wrapping: MountFixtures.FastTool(),
                arguments: MountArguments(value: "stop me"),
                sink: DiscardingOperationEventSink()
            )
            let stop: @Sendable (@escaping Canceler) async -> OperationOutcome? = { await run.stop(using: $0) }
            return TwoStops(first: stop, second: stop, finish: {})
        case .processRunCancelTwice, .processRunCancelThenSweep:
            let gate = RunLatch()
            let harness = MountFixtures.backgroundHarness(
                wrapping: MountFixtures.GatedProcessTool(gate: gate, processCanceler: processCanceler)
            )
            _ = try await harness.mounted.call(arguments: MountArguments(value: "long job"))
            let run = try #require(await harness.runPlane.backgroundRuns().first)
            #expect(run.kind == .process)
            let runPlane = harness.runPlane
            let token = run.completionToken
            let cancel: @Sendable (@escaping Canceler) async -> OperationOutcome? = { _ in
                await runPlane.cancel(completionToken: token).reportedOutcome
            }
            let sweep: @Sendable (@escaping Canceler) async -> OperationOutcome? = { _ in
                await runPlane.sweep().first { $0.correlationID == token }?.outcome
            }
            return TwoStops(first: cancel, second: route == .processRunCancelTwice ? cancel : sweep, finish: { gate.open() })
        }
    }

    // MARK: - Two stops

    @Test(
        "a second stop reports the outcome of the first stop, and only the first canceler runs, one time",
        arguments: StopRoute.allCases
    )
    func aSecondStopKeepsTheFirstStop(route: StopRoute) async throws {
        let calls = Recorder<String>()
        let first = Self.recordingCanceler(named: Self.firstCancelerName, into: calls, reporting: .stopped)
        let second = Self.recordingCanceler(named: Self.secondCancelerName, into: calls, reporting: .cancelled)
        let stops = try await Self.twoStops(through: route, processCanceler: first)

        #expect(await stops.first(first) == .stopped)
        #expect(await stops.second(second) == .stopped)
        #expect(calls.values == [Self.firstCancelerName])

        stops.finish()
    }

    // MARK: - The task of the stop

    @Test("a second stop while the first canceler still runs gets the task of the first stop")
    func aSecondStopDuringTheFirstStopGetsItsTask() async {
        let state = ToolCallState()
        let calls = Recorder<String>()
        let gate = RunLatch()
        let first = state.stop {
            calls.append(Self.firstCancelerName)
            await gate.waitUntilOpen()
            return .stopped
        }

        // The first canceler waits on the gate, so the first stop is not done.
        let second = state.stop(using: Self.recordingCanceler(named: Self.secondCancelerName, into: calls, reporting: .cancelled))
        #expect(first == second)

        gate.open()
        #expect(await state.stopOutcome == .stopped)
        #expect(calls.values == [Self.firstCancelerName])
    }

    @Test("a call state with no stop has no stop outcome")
    func aStateWithNoStopHasNoOutcome() async {
        #expect(await ToolCallState().stopOutcome == nil)
    }
}
