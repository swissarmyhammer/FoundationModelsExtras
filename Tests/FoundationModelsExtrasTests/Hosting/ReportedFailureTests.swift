@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// Exercises ``ToolContext/reportFailure(value:)``: a tool returns its output
/// text and ends the run as failed, with a value. A stop, a timeout and a
/// cancel win over the report.
@Suite("Reported failure: a tool returns its output and ends the run as failed with a value")
struct ReportedFailureTests {
    private typealias Fixtures = MountFixtures

    /// The exit code that the fixture tools report.
    private static let exitCode = 2

    /// The output of each fixture tool.
    private static let output = "command output"

    /// Reports a failure with ``exitCode``, then returns ``output``. When it
    /// has a gate, it waits on the gate between the report and the return.
    private struct ReportingTool: Tool {
        let name = "reporting_tool"
        let description = "reports a failure with an exit code, then returns its output"

        /// The gate that the tool waits on after the report, or `nil` for none.
        let gate: RunLatch?

        init(gate: RunLatch? = nil) {
            self.gate = gate
        }

        func call(arguments: MountArguments) async throws -> String {
            ToolContext.current?.reportFailure(value: .int(ReportedFailureTests.exitCode))
            await gate?.waitUntilOpen()
            return ReportedFailureTests.output
        }
    }

    /// Reports a failure, then waits until its task is cancelled.
    private struct ReportingSleepingTool: Tool {
        let name = "reporting_sleeping_tool"
        let description = "reports a failure, then sleeps until cancelled"

        func call(arguments: MountArguments) async throws -> String {
            ToolContext.current?.reportFailure(value: .int(ReportedFailureTests.exitCode))
            try await Waits.untilCancelled()
            return "never returned"
        }
    }

    /// The terminal event of one call of `tool` through a run-to-completion
    /// runner, and the text that the call returned.
    private static func callToCompletion(_ tool: any Tool<MountArguments, String>) async throws -> (
        terminal: OperationEvent, returned: String
    ) {
        let harness = Fixtures.runToCompletionHarness(wrapping: tool)
        let returned = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let terminal = try #require(await harness.sink.events.last)
        return (terminal, returned)
    }

    /// The terminal event of a run of `tool` that `interrupt` interrupts
    /// while the tool waits on its gate.
    ///
    /// - Parameters:
    ///   - tool: The tool to run. It waits on its gate after its report.
    ///   - interrupt: Interrupts the run. It gets the run and the task that
    ///     executes it.
    /// - Returns: The terminal event of the run.
    private static func terminal(
        ofRunning tool: ReportingTool,
        interruptedBy interrupt: (ToolRun<MountArguments>, Task<RunSettlement, Never>) async -> Void
    ) async throws -> OperationEvent {
        let arguments = MountArguments(value: "x")
        let run = Fixtures.toolRun(wrapping: tool, arguments: arguments, sink: Fixtures.RecordingSink())
        let executing = Task { await run.execute(arguments: arguments) }
        await interrupt(run, executing)
        tool.gate?.open()
        return await executing.value.terminal
    }

    // MARK: - A reported failure

    @Test("a tool that reports a failure gives a failed terminal event with the output as its detail")
    func aReportedFailureGivesAFailedTerminalWithTheOutput() async throws {
        let call = try await Self.callToCompletion(ReportingTool())

        #expect(call.terminal.kind == .completed)
        #expect(call.terminal.outcome == .failed)
        #expect(call.terminal.detail == Self.output)
    }

    @Test("a tool that reports a failure with an exit code gives the exit code as the value of the terminal event")
    func aReportedFailureGivesTheValue() async throws {
        let call = try await Self.callToCompletion(ReportingTool())

        #expect(call.terminal.value == .int(Self.exitCode))
    }

    @Test("a tool that reports a failure still returns its output to the model, with no error")
    func aReportedFailureLeavesTheModelFacingReturnAlone() async throws {
        let call = try await Self.callToCompletion(ReportingTool())

        #expect(call.returned == Self.output)
    }

    // MARK: - No context

    @Test("a tool that reports a failure with no context bound returns its output and does nothing else")
    func aReportOnABareSessionIsANoOp() async throws {
        #expect(ToolContext.current == nil)

        let returned = try await ReportingTool().call(arguments: MountArguments(value: "x"))

        #expect(returned == Self.output)
    }

    // MARK: - A tool that does not report

    @Test("a tool that does not report gives the same silence as before: no terminal event for a silent success")
    func anUnreportedSuccessPostsNothing() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.FastTool())

        _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(await harness.sink.events.isEmpty)
    }

    @Test("a tool that throws and does not report gives a failed terminal event with no value")
    func anUnreportedThrowGivesNoValue() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ThrowingTool<MountArguments, String>())

        _ = try? await harness.mounted.call(arguments: MountArguments(value: "x"))

        let terminal = try #require(await harness.sink.events.last)
        #expect(terminal.outcome == .failed)
        #expect(terminal.value == nil)
    }

    // MARK: - A stop, a timeout and a cancel win

    @Test("a stop wins over a reported failure: the outcome is stopped, with no value")
    func aStopWinsOverAReportedFailure() async throws {
        let terminal = try await Self.terminal(ofRunning: ReportingTool(gate: RunLatch())) { run, _ in
            _ = await run.stop(using: { .stopped })
        }

        #expect(terminal.outcome == .stopped)
        #expect(terminal.value == nil)
    }

    @Test("a cancel wins over a reported failure of a tool that returns after the cancel")
    func aCancelWinsOverAReportedFailure() async throws {
        let terminal = try await Self.terminal(ofRunning: ReportingTool(gate: RunLatch())) { _, executing in
            executing.cancel()
        }

        #expect(terminal.outcome == .cancelled)
        #expect(terminal.value == nil)
    }

    @Test("a timeout wins over a reported failure: the outcome is timedOut, with no value")
    func aTimeoutWinsOverAReportedFailure() async throws {
        let clock = ManualRunClock()
        let sink = Fixtures.RecordingSink()
        let site = Fixtures.site(runPlane: RunPlane(clock: clock), sink: sink)
        let mounted = RunToCompletionRunner(
            wrapping: ReportingSleepingTool(), site: site, timeout: Fixtures.shortInterval)
        let calling = Task { try await mounted.call(arguments: MountArguments(value: "x")) }

        await #expect(throws: ToolMountError.self) {
            _ = try await clock.elapse(Fixtures.shortInterval, endingWait: calling)
        }

        let terminal = try #require(await sink.events.last)
        #expect(terminal.outcome == .timedOut)
        #expect(terminal.value == nil)
    }
}
