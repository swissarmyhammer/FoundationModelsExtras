@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises the stop of one call: ``ToolRun/stop(using:)`` and
/// ``ToolCallState/stop(using:)``.
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

    // MARK: - Arguments

    /// The arguments of the fixture tool of this suite.
    @Generable
    struct ToolRunStopArguments {
        /// A value that the tool echoes back.
        let value: String
    }

    // MARK: - Tools

    /// Echoes its argument. The tests of this suite stop the run and do not
    /// call the tool.
    private struct EchoTool: Tool {
        let name = "tool_run_stop_echo"
        let description = "echoes its argument"

        func call(arguments: ToolRunStopArguments) async throws -> String {
            arguments.value
        }
    }

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

    /// Makes one run of ``EchoTool`` on a new run plane, with no timeout.
    private static func makeRun() -> ToolRun<ToolRunStopArguments> {
        ToolRun(
            wrapped: EchoTool(),
            arguments: ToolRunStopArguments(value: "stop me"),
            site: MountSite(sessionID: ULID(), runPlane: RunPlane(), sink: DiscardingOperationEventSink()),
            mountTimeout: nil
        )
    }

    // MARK: - ToolCallState

    @Test("a second stop on the call state gets the task of the first stop, and its own canceler never runs")
    func aSecondStateStopReturnsTheFirstTask() async {
        let state = ToolCallState()
        let calls = Recorder<String>()

        let first = state.stop(using: Self.recordingCanceler(named: Self.firstCancelerName, into: calls, reporting: .stopped))
        let second = state.stop(using: Self.recordingCanceler(named: Self.secondCancelerName, into: calls, reporting: .cancelled))

        #expect(first == second)
        #expect(await first.value == .stopped)
        #expect(await second.value == .stopped)
        #expect(calls.values == [Self.firstCancelerName])
        #expect(await state.stopOutcome == .stopped)
    }

    @Test("a second stop while the first canceler still runs gets the same task, and both stops report its outcome")
    func aSecondStateStopDuringTheFirstStopWaitsForIt() async {
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

        #expect(await second.value == .stopped)
        #expect(await first.value == .stopped)
        #expect(calls.values == [Self.firstCancelerName])
    }

    @Test("a call state with no stop has no stop outcome")
    func aStateWithNoStopHasNoOutcome() async {
        #expect(await ToolCallState().stopOutcome == nil)
    }

    // MARK: - ToolRun

    @Test("two stops of one run give the outcome of the first canceler, and the canceler runs one time")
    func twoRunStopsRunTheCancelerOneTime() async {
        let run = Self.makeRun()
        let calls = Recorder<String>()
        let canceler = Self.recordingCanceler(named: Self.firstCancelerName, into: calls, reporting: .stopped)

        let firstOutcome = await run.stop(using: canceler)
        let secondOutcome = await run.stop(using: canceler)

        #expect(firstOutcome == .stopped)
        #expect(secondOutcome == .stopped)
        #expect(calls.values == [Self.firstCancelerName])
    }

    @Test("a second stop of one run with a different canceler reports the outcome of the first canceler")
    func aSecondRunStopKeepsTheFirstOutcome() async {
        let run = Self.makeRun()
        let calls = Recorder<String>()

        let firstOutcome = await run.stop(
            using: Self.recordingCanceler(named: Self.firstCancelerName, into: calls, reporting: .stopped)
        )
        let secondOutcome = await run.stop(
            using: Self.recordingCanceler(named: Self.secondCancelerName, into: calls, reporting: .cancelled)
        )

        #expect(firstOutcome == .stopped)
        #expect(secondOutcome == .stopped)
        #expect(calls.values == [Self.firstCancelerName])
    }
}
