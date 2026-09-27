@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// Exercises the ``RunKind`` and the canceler that a tool declares through
/// ``BackgroundTool``.
///
/// A capability that owns an OS process group kills it, which is certain, so
/// its canceler reports ``OperationOutcome/stopped``. The cooperative canceler
/// only asks the work to stop, so it reports ``OperationOutcome/cancelled``.
/// The two stay apart. Each fixture reaches the run plane through the
/// protocol and ``ToolContext`` only.
@Suite("Declared run kind: a tool states its own RunKind and gives its own canceler")
struct DeclaredRunKindTests {
    // MARK: - Intervals

    /// A sleep that only a cancel ends.
    private static let unendingSleepNanoseconds: UInt64 = 3_600_000_000_000

    /// The limit of each wait on the run plane, so a broken handshake ends the
    /// test and does not stop the suite.
    private static let settlementDeadline: TimeInterval = 30

    // MARK: - Arguments

    /// The arguments of each fixture tool of this suite.
    @Generable
    struct DeclaredRunKindArguments {
        /// A value that the tool echoes back.
        let value: String
    }

    // MARK: - Tools

    /// Keeps the completion token of each run whose process group a canceler
    /// killed.
    private actor KillWitness {
        /// The killed tokens, in kill order.
        private(set) var killedTokens: [String] = []

        /// Records one kill.
        ///
        /// - Parameter completionToken: The completion token of the killed run.
        func recordKill(completionToken: String) {
            killedTokens.append(completionToken)
        }
    }

    /// Goes to the background, declares ``RunKind/process``, and gives the
    /// canceler that its capability owns.
    ///
    /// The canceler stands for `killpg(SIGKILL)`: it records the kill and
    /// reports ``OperationOutcome/stopped``. It signals nothing: the body's
    /// wait on the group is `gate`, which each test opens.
    private struct DeclaredProcessTool: Tool, BackgroundTool {
        let name = "declared_process_tool"
        let description = "is backgrounded at once as a process run and kills its own group"

        /// The wait of the run on its process group.
        let gate: RunLatch

        /// Records each kill of the canceler of this tool.
        let witness: KillWitness

        func call(arguments: DeclaredRunKindArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "process: \(arguments.value)"
        }

        var runKind: RunKind { .process }

        func canceler(forCompletionToken completionToken: String) -> (@Sendable () async -> OperationOutcome)? {
            let witness = witness
            return {
                await witness.recordKill(completionToken: completionToken)
                return .stopped
            }
        }
    }

    /// Sleeps until it is cancelled and declares nothing.
    private struct UndeclaredKindTool: Tool {
        let name = "undeclared_kind_tool"
        let description = "sleeps until cancelled and declares no mount parameters"

        func call(arguments: DeclaredRunKindArguments) async throws -> String {
            try await Task.sleep(nanoseconds: DeclaredRunKindTests.unendingSleepNanoseconds)
            return "never returned"
        }
    }

    // MARK: - Harness

    /// The wiring of one test.
    private struct Harness {
        /// The run plane of each run of this harness.
        let runPlane: RunPlane

        /// The host context that reads and cancels the run plane.
        let context: ToolContext

        /// The sink of each run, so a test can count terminal events.
        let sink: MountFixtures.RecordingSink

        /// The background runner under test.
        let background: BackgroundToolRunner<DeclaredRunKindArguments>
    }

    /// The tool name of the host context of the harness.
    private static let hostToolName = "run_plane_host"

    /// The op of the host context of the harness.
    private static let hostOp = "read runs"

    /// Wraps `tool` in a ``BackgroundToolRunner`` over a new run plane, beside
    /// a host context on that run plane.
    private static func makeHarness(backgroundMounting tool: any Tool<DeclaredRunKindArguments, String>) -> Harness {
        let runPlane = RunPlane()
        let sessionID = ULID()
        let sink = MountFixtures.RecordingSink()
        let background = BackgroundToolRunner(
            wrapping: tool, site: MountSite(sessionID: sessionID, runPlane: runPlane, sink: sink), timeout: nil
        )
        let context = ToolContext(
            sessionID: sessionID,
            runPlane: runPlane,
            sink: DiscardingOperationEventSink(),
            tool: hostToolName,
            op: hostOp,
            completionToken: RunPlane.makeCompletionToken(),
            isCancelled: { false }
        )
        return Harness(runPlane: runPlane, context: context, sink: sink, background: background)
    }

    /// Sends one call of the runner of `harness` to the background, and
    /// returns the run.
    private static func backgroundOneRun(through harness: Harness) async throws -> BackgroundRun {
        let rendered = try await harness.background.call(arguments: DeclaredRunKindArguments(value: "long job"))
        // The call went to the background: the model got a pending envelope.
        #expect(PendingRunEnvelope.isRendered(text: rendered))
        let runs = await harness.context.backgroundRuns()
        #expect(runs.count == 1)
        return try #require(runs.first)
    }

    // MARK: - A declared process run

    @Test("a tool that declares .process goes to the background under that kind, and ToolContext.backgroundRuns() lists it so")
    func aDeclaredProcessRunIsListedAsProcess() async throws {
        let gate = RunLatch()
        let harness = Self.makeHarness(backgroundMounting: DeclaredProcessTool(gate: gate, witness: KillWitness()))

        let run = try await Self.backgroundOneRun(through: harness)

        #expect(run.kind == .process)

        gate.open()
        _ = await harness.context.wait(completionToken: run.completionToken, seconds: Self.settlementDeadline)
    }

    @Test("a cancel of a run whose tool gave its own canceler reports the .stopped of that canceler")
    func cancellingADeclaredProcessRunReportsStopped() async throws {
        let gate = RunLatch()
        let witness = KillWitness()
        let harness = Self.makeHarness(backgroundMounting: DeclaredProcessTool(gate: gate, witness: witness))

        let run = try await Self.backgroundOneRun(through: harness)

        // .stopped is certain and .cancelled is a request. The cooperative
        // canceler only reports the second, so this outcome shows that the
        // canceler of the tool ran.
        #expect(await harness.context.cancel(completionToken: run.completionToken) == .reported(.stopped))
        #expect(await witness.killedTokens == [run.completionToken])

        gate.open()
        _ = await harness.context.wait(completionToken: run.completionToken, seconds: Self.settlementDeadline)
    }

    // MARK: - The terminal event of a stopped process run

    /// Waits on `run` through the host context and returns its terminal event.
    private static func settledTerminal(of run: BackgroundRun, through harness: Harness) async throws -> OperationEvent {
        let outcome = await harness.context.wait(completionToken: run.completionToken, seconds: Self.settlementDeadline)
        return try #require(outcome.settledTerminal, "run \(run.completionToken) did not settle: \(outcome)")
    }

    /// Cancels `run` through the host context, lets its body end on `gate`,
    /// and returns the terminal event.
    private static func stopAndSettle(run: BackgroundRun, through harness: Harness, opening gate: RunLatch) async throws -> OperationEvent {
        #expect(await harness.context.cancel(completionToken: run.completionToken) == .reported(.stopped))
        gate.open()
        return try await settledTerminal(of: run, through: harness)
    }

    @Test("a .process run that its canceler stopped settles with .stopped, never .succeeded, and posts one terminal event")
    func aStoppedProcessRunSettlesWithItsCancelersOutcome() async throws {
        let gate = RunLatch()
        let harness = Self.makeHarness(backgroundMounting: DeclaredProcessTool(gate: gate, witness: KillWitness()))
        let run = try await Self.backgroundOneRun(through: harness)

        // The kill does not cancel the body: it returns normally, as the reap
        // of a killed process group does. The terminal event must still say
        // stopped.
        let terminal = try await Self.stopAndSettle(run: run, through: harness, opening: gate)

        #expect(terminal.outcome == .stopped)
        #expect(terminal.correlationID == run.completionToken)
        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .stopped)
    }

    @Test("wait on a .process run that a cancel stopped reports the kept .stopped terminal event")
    func waitOnAStoppedProcessRunReportsStopped() async throws {
        let gate = RunLatch()
        let harness = Self.makeHarness(backgroundMounting: DeclaredProcessTool(gate: gate, witness: KillWitness()))
        let run = try await Self.backgroundOneRun(through: harness)
        _ = try await Self.stopAndSettle(run: run, through: harness, opening: gate)

        // The run settled, so this wait reads the kept terminal event.
        let retained = try await Self.settledTerminal(of: run, through: harness)

        #expect(retained.outcome == .stopped)
        #expect(await harness.context.cancel(completionToken: run.completionToken) == .alreadySettled(retained))
    }

    // MARK: - A tool that declares nothing

    @Test("a tool that declares nothing goes to the background as .swiftTask, and a cancel reports the cooperative .cancelled")
    func aToolDeclaringNothingKeepsTheCooperativeCanceler() async throws {
        let harness = Self.makeHarness(backgroundMounting: UndeclaredKindTool())

        let run = try await Self.backgroundOneRun(through: harness)

        #expect(run.kind == .swiftTask)
        #expect(await harness.context.cancel(completionToken: run.completionToken) == .reported(.cancelled))

        // The cooperative request reaches the body: the sleep throws, and the
        // run settles as cancelled.
        let terminal = try await Self.settledTerminal(of: run, through: harness)
        #expect(terminal.outcome == .cancelled)
    }

    // MARK: - The sweep

    @Test("the sweep reaches a declared .process run and calls the canceler that its tool gave")
    func theSweepCallsTheToolsOwnCanceler() async throws {
        let gate = RunLatch()
        let witness = KillWitness()
        let harness = Self.makeHarness(backgroundMounting: DeclaredProcessTool(gate: gate, witness: witness))

        let run = try await Self.backgroundOneRun(through: harness)

        let terminals = await harness.runPlane.sweep()

        #expect(await witness.killedTokens == [run.completionToken])
        #expect(terminals.count == 1)
        #expect(terminals.first?.correlationID == run.completionToken)
        #expect(terminals.first?.outcome == .stopped)
        #expect(await harness.context.backgroundRuns().isEmpty)

        gate.open()
    }
}
