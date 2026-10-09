@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// ``ToolContext/mount(_:op:as:)``: a caller outside this package mounts a
/// tool on a running session with it.
///
/// Each test calls the returned tool directly, with no conditional cast, and
/// reads the events of the mounted run from the sink of the mounting context.
@Suite("ToolContext.mount: mount a tool on the running context", .timeLimit(.minutes(1)))
struct ToolContextMountTests {
    private typealias Fixtures = MountFixtures

    /// The tool stamp of the run that each test mounts under.
    private static let hostTool = "host_tool"

    /// The op stamp of the run that each test mounts under.
    private static let hostOp = "host run"

    /// The completion token of the run that each test mounts under.
    private static let hostToken = "host-run-token"

    /// The wiring of one test: the context of the mounting run, and its run
    /// plane, sink and records.
    private struct Host {
        /// The context that each mount is made on.
        let context: ToolContext

        /// The run plane that tracks the mounted runs.
        let runPlane: RunPlane

        /// The sink that gets the events of the mounted runs.
        let sink: Fixtures.RecordingSink

        /// The records of the mounting run.
        let attachments: ToolCallState
    }

    /// The wiring of the mounting run, stamped with ``hostTool``, ``hostOp``
    /// and ``hostToken``.
    ///
    /// - Parameter inlineSettleGrace: The settle period of the context. The
    ///   default is ``MountFixtures/pendingAtOnceGrace``, so each background
    ///   call answers with its pending envelope at once.
    /// - Returns: A new context over a new run plane, sink and record store.
    private static func makeHost(inlineSettleGrace: TimeInterval = Fixtures.pendingAtOnceGrace) -> Host {
        let runPlane = RunPlane()
        let sink = Fixtures.RecordingSink()
        let attachments = ToolCallState()
        let context = ToolContext(
            sessionID: ULID(),
            runPlane: runPlane,
            sink: sink,
            tool: hostTool,
            op: hostOp,
            completionToken: hostToken,
            isCancelled: { false },
            attachmentSink: { attachments.attach($0) },
            inlineSettleGrace: inlineSettleGrace
        )
        return Host(context: context, runPlane: runPlane, sink: sink, attachments: attachments)
    }

    /// The settle period of an outer run that makes an inner call inside it.
    /// It is longer than ``BackgroundToolRunner/innerCallSettleReserve``, so
    /// the inner call keeps a short wait.
    private static let outerSettleGrace: TimeInterval = 1.3

    /// The grace that an inner tool states for the test of an outer run that
    /// already answered.
    private static let innerSettleGrace: TimeInterval = 0.3

    /// The output of ``InnerCallTimingTool``.
    private static let outerOutput = "outer: done"

    /// What the inner call of ``InnerCallTimingTool`` gave.
    private actor InnerCallWitness {
        /// The seconds that the inner call took.
        private(set) var elapsed: TimeInterval?

        /// The output of the inner call.
        private(set) var output: String?

        /// Keeps the facts of the inner call.
        func record(elapsed: TimeInterval, output: String) {
            self.elapsed = elapsed
            self.output = output
        }
    }

    /// Mounts `inner` as a background tool on its own context, calls it, and
    /// records the time and the output of that inner call.
    private struct InnerCallTimingTool: Tool {
        let name = "inner_call_timing_tool"
        let description = "makes one inner background call and records how long it took"
        let inner: Fixtures.InlineGraceTool
        let witness: InnerCallWitness

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let mounted = context.mount(inner, as: ToolMount(mode: .background))
            let start = ContinuousClock.now
            let output = try await mounted.call(arguments: arguments)
            await witness.record(elapsed: ToolContextMountTests.seconds(since: start), output: output)
            return ToolContextMountTests.outerOutput
        }
    }

    /// The seconds from `start` to now.
    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let parts = (ContinuousClock.now - start).components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    // MARK: - The three decorators

    @Test(
        "mounting a String-output tool as background gives the call back as a completion token on the run plane of the context"
    )
    func mountsStringOutputToolInTheBackground() async throws {
        let gate = RunLatch()
        let host = Self.makeHost()

        let mounted = host.context.mount(Fixtures.GatedTool(gate: gate), op: "run gate", as: ToolMount(mode: .background))

        #expect(mounted is BackgroundToolRunner<MountArguments>)
        let rendered = try await mounted.call(arguments: MountArguments(value: "mounted"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.isPending)
        // The run plane of the mounting context tracks the run, under the op
        // of the mount call.
        #expect(await host.runPlane.backgroundRuns().map(\.op) == ["run gate"])

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: host.runPlane)
        #expect(terminal.detail == "gated: mounted")
    }

    @Test("mounting a String-output tool with the default mount runs it to completion in band")
    func mountsStringOutputToolRunToCompletion() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(Fixtures.FastTool())

        #expect(mounted is RunToCompletionRunner<MountArguments>)
        let rendered = try await mounted.call(arguments: MountArguments(value: "in-band"))
        #expect(rendered == "fast: in-band")
        // No token came back: the call stayed in band.
        #expect(await host.runPlane.backgroundRuns().isEmpty)
    }

    @Test("mounting a non-String-output tool binds it and gives its own output back unchanged")
    func mountsNonStringOutputToolInTheBindingDecorator() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(Fixtures.NonStringOutputTool())

        #expect(mounted is ContextBindingTool<MountArguments, NonStringToolOutput>)
        let output = try await mounted.call(arguments: MountArguments(value: "silent"))
        #expect(output.text == "ignored")
        // A silent run posts nothing.
        #expect(await host.sink.events.isEmpty)
    }

    // MARK: - The mount that a tool declares

    @Test("the mount that a tool declares wins over the mount that the call gives")
    func declaredMountWinsOverTheConfigurationArgument() async throws {
        let host = Self.makeHost()

        // The tool declares background with no timeout, and the call asks
        // for the synchronous mount. The gate never opens: the test reads the
        // mount, and does not call through it.
        let mounted = host.context.mount(Fixtures.DeclaredBackgroundToolRunner(gate: RunLatch()), as: .synchronous)

        // Only the declaration explains the decorator and its timeout.
        let runner = try #require(mounted as? BackgroundToolRunner<MountArguments>)
        #expect(runner.timeout == nil)
    }

    // MARK: - The event route

    @Test("the events of a mounted tool reach the sink under the correlation of the mounting context")
    func mountedToolEventsCarryTheContextCorrelation() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(AmbientNonStringOutputTool())
        let output = try await mounted.call(arguments: AmbientToolArguments(value: "inner"))

        let events = await host.sink.events
        #expect(events.map(\.detail) == ["inner"])
        // The mounting context stamps each event that it forwards, so the sink
        // sees the mounting run and never the inner run.
        #expect(events.map(\.tool) == [Self.hostTool])
        #expect(events.map(\.op) == [Self.hostOp])
        #expect(events.map(\.correlationID) == [Self.hostToken])
        // The inner run keeps a completion token of its own: the fixture
        // returns the token of its bound context.
        #expect(output.text != Self.hostToken)
        #expect(ULID(ulidString: output.text) != nil)
    }

    @Test("the display events of a mounted tool reach the sink stamped again under the token of the mounting context")
    func mountedToolDisplayEventsCarryTheContextCorrelation() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(Fixtures.DisplayOnceTool())
        _ = try await mounted.call(arguments: MountArguments(value: "inner chunk"))

        let expected = ToolDisplayEvent(
            tool: Self.hostTool, op: Self.hostOp, correlationID: Self.hostToken,
            kind: .contentChunk(.text("inner chunk")))
        #expect(await host.sink.displays == [expected])
        // The display event is not an operation event of the mounting run.
        #expect(await host.sink.events.isEmpty)
    }

    @Test("a mounted call that fails and is caught leaves the one terminal event to the mounting run")
    func caughtMountedFailureLeavesTheTerminalToTheMountingRun() async throws {
        let run = await Self.nestingRun(around: Fixtures.ThrowingTool())

        #expect(run.settled.outcome == .succeeded)
        // The sink gets one terminal event: the terminal of the mounting run,
        // and not the `.failed` terminal of the mounted call.
        #expect(run.sinkTerminals == [run.settled])
    }

    @Test("a mounted call that posts progress and succeeds leaves the one terminal event to the mounting run")
    func progressingMountedSuccessLeavesTheTerminalToTheMountingRun() async throws {
        let run = await Self.nestingRun(around: Fixtures.ProgressOnceTool())

        #expect(run.settled.outcome == .succeeded)
        #expect(run.sinkTerminals == [run.settled])
    }

    @Test("the terminal event of a mounted call reaches the sink as progress of the mounting run")
    func mountedTerminalReachesTheSinkAsProgress() async throws {
        let run = await Self.nestingRun(around: Fixtures.ThrowingTool())

        // The end of the mounted call is progress of the mounting run, with
        // the detail of the mounted call.
        #expect(run.events.map(\.kind) == [.progress, .completed])
        #expect(run.events.first?.detail == String(describing: Fixtures.FixtureError()))
        #expect(run.events.first?.outcome == nil)
    }

    /// What one run of ``MountFixtures/NestingTool`` gave.
    private struct NestingRun {
        /// Each event on the sink of the run, in post order.
        let events: [OperationEvent]

        /// The terminal event that the run settled with.
        let settled: OperationEvent

        /// The terminal events on the sink of the run, in post order.
        var sinkTerminals: [OperationEvent] {
            events.filter { $0.kind == .completed }
        }
    }

    /// Runs ``MountFixtures/NestingTool`` around `inner` to completion, with a
    /// recording sink.
    ///
    /// - Parameter inner: The tool that the nesting tool mounts and calls.
    /// - Returns: The events on the sink and the terminal of the run.
    private static func nestingRun(around inner: any Tool<MountArguments, String>) async -> NestingRun {
        let sink = Fixtures.RecordingSink()
        let arguments = MountArguments(value: "outer")
        let run = Fixtures.toolRun(wrapping: Fixtures.NestingTool(inner: inner), arguments: arguments, sink: sink)

        await run.open()
        let settlement = await run.execute(arguments: arguments)

        return NestingRun(events: await sink.events, settled: settlement.terminal)
    }

    // MARK: - The attachment route

    @Test("the records of a mounted tool reach the mounting context, and the mounted call posts no report")
    func mountedToolAttachmentsReachTheMountingContext() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(Fixtures.AttachingTool())
        _ = try await mounted.call(arguments: MountArguments(value: "nested"))

        // The records of the nested call are on the mounting run, in call order.
        #expect(host.attachments.drainAttachments() == Fixtures.attachmentsInCallOrder)
        // The sink of the mounting context got no report and no event.
        #expect(await host.sink.reports.isEmpty)
        #expect(await host.sink.events.isEmpty)
    }

    @Test(
        "in a run-to-completion call, the records of a nested mounted call go on the report of the mounting call, under its correlationID"
    )
    func nestedCallAttachmentsRideTheMountingCallReport() async throws {
        let sink = Fixtures.RecordingSink()
        let arguments = MountArguments(value: "outer")
        let run = Fixtures.toolRun(wrapping: Fixtures.NestingAttachingTool(), arguments: arguments, sink: sink)

        await run.open()
        let settlement = await run.execute(arguments: arguments)

        #expect(settlement.attachments == Fixtures.attachmentsInCallOrder)
        // One report: the report of the mounting call, under its own token.
        let reports = await sink.reports
        #expect(reports.map(\.correlationID) == [run.context.completionToken])
        #expect(reports.map(\.tool) == [run.context.tool])
        #expect(reports.map(\.attachments) == [Fixtures.attachmentsInCallOrder])
    }

    // MARK: - The return type

    @Test("the mounted tool keeps the Arguments and the Output of the wrapped tool, so a caller needs no cast")
    func theReturnTypeCarriesArgumentsAndOutput() async throws {
        let host = Self.makeHost()

        // The annotations are the assertion: each mount has the `Arguments`
        // and the `Output` of the wrapped tool, with no conditional cast.
        let inBand: any Tool<MountArguments, String> = host.context.mount(Fixtures.FastTool())
        let backgrounded: any Tool<MountArguments, String> = host.context.mount(
            Fixtures.FastTool(), as: ToolMount(mode: .background))
        let bound: any Tool<AmbientToolArguments, NonStringToolOutput> = host.context.mount(
            AmbientNonStringOutputTool())

        let rendered = try await inBand.call(arguments: MountArguments(value: "typed"))
        #expect(rendered == "fast: typed")

        let pending = try await backgrounded.call(arguments: MountArguments(value: "typed"))
        #expect(try Fixtures.decodeEnvelope(pending).isPending)

        let output = try await bound.call(arguments: AmbientToolArguments(value: "typed"))
        #expect(!output.text.isEmpty)
    }

    // MARK: - The settle period of a mounted call

    @Test("a context takes ToolMount.defaultInlineSettleGrace when its host states none, and the value that its host states")
    func contextCarriesTheConfiguredSettlePeriod() {
        let defaulted = ToolContext(
            sessionID: ULID(), runPlane: RunPlane(), sink: Fixtures.RecordingSink(), tool: Self.hostTool,
            op: Self.hostOp, completionToken: Self.hostToken, isCancelled: { false })
        let stated = Self.makeHost(inlineSettleGrace: Self.innerSettleGrace)

        #expect(defaulted.inlineSettleGrace == ToolMount.defaultInlineSettleGrace)
        #expect(stated.context.inlineSettleGrace == Self.innerSettleGrace)
    }

    @Test("settling(within:) changes the grace that inner mounts use, and a negative value acts as 0")
    func settlingWithinChangesTheGraceOfInnerMounts() async throws {
        let host = Self.makeHost(inlineSettleGrace: Fixtures.pendingAtOnceGrace)
        let waiting = host.context.settling(within: Fixtures.generousInterval)
        let atOnce = waiting.settling(within: -1)

        #expect(waiting.inlineSettleGrace == Fixtures.generousInterval)
        #expect(atOnce.inlineSettleGrace == 0)
        // The original context keeps its own value.
        #expect(host.context.inlineSettleGrace == Fixtures.pendingAtOnceGrace)

        let inline = try await waiting.mount(Fixtures.FastTool(), as: ToolMount(mode: .background))
            .call(arguments: MountArguments(value: "inline"))
        let pending = try await atOnce.mount(Fixtures.FastTool(), as: ToolMount(mode: .background))
            .call(arguments: MountArguments(value: "pending"))

        #expect(inline == "fast: inline")
        let envelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: pending))
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: host.runPlane)
    }

    @Test("an inner background call inside the settle period of its outer run stops its wait the reserve before the outer deadline, so the outer run answers inline")
    func innerCallInsideTheOuterSettlePeriodKeepsTheReserve() async throws {
        let gate = RunLatch()
        let witness = InnerCallWitness()
        // The inner tool asks for a long wait, and its gate stays closed.
        let inner = Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval)
        let harness = Fixtures.backgroundHarness(
            wrapping: InnerCallTimingTool(inner: inner, witness: witness), inlineSettleGrace: Self.outerSettleGrace)
        let start = ContinuousClock.now

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "nested"))

        // The outer run ended inside its own grace: its own output, no envelope.
        #expect(rendered == Self.outerOutput)
        #expect(Self.seconds(since: start) < Self.outerSettleGrace)
        // The inner call stopped its wait before the outer deadline, and left
        // the reserve to the outer run.
        let elapsed = try #require(await witness.elapsed)
        let reserve = BackgroundToolRunner<MountArguments>.innerCallSettleReserve
        #expect(elapsed < Self.outerSettleGrace - reserve / 2)
        let innerOutput = try #require(await witness.output)
        let innerEnvelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: innerOutput))

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: innerEnvelope.completionToken, in: harness.runPlane)
        #expect(terminal.detail == Fixtures.InlineGraceTool.output(for: "nested"))
    }

    @Test("an inner background call after the outer run already answered waits for its full grace")
    func innerCallAfterTheOuterDeadlineWaitsItsFullGrace() async throws {
        let gate = RunLatch()
        let witness = InnerCallWitness()
        let inner = Fixtures.InlineGraceTool(gate: gate, grace: Self.innerSettleGrace)
        // Grace 0: the outer run answers at once, so its deadline passed
        // before the inner call starts.
        let harness = Fixtures.backgroundHarness(
            wrapping: InnerCallTimingTool(inner: inner, witness: witness), inlineSettleGrace: 0)

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "late"))
        let outerEnvelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: rendered))
        let outerTerminal = try await Fixtures.settledTerminal(of: outerEnvelope.completionToken, in: harness.runPlane)

        #expect(outerTerminal.detail == Self.outerOutput)
        let elapsed = try #require(await witness.elapsed)
        #expect(elapsed >= Self.innerSettleGrace * 0.9)
        let innerOutput = try #require(await witness.output)
        let innerEnvelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: innerOutput))

        gate.open()
        _ = try await Fixtures.settledTerminal(of: innerEnvelope.completionToken, in: harness.runPlane)
    }
}
