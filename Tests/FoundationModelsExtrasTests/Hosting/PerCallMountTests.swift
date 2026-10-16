@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// ``BackgroundTool/mount(for:)``: one tool runs some calls in the background
/// and other calls to completion, and the tool chooses for each call.
@Suite("Per-call mount: a tool chooses background or synchronous for each call")
struct PerCallMountTests {
    private typealias Fixtures = MountFixtures

    /// The value that makes ``PerCallMountTool`` start a background run.
    private static let backgroundValue = "start"

    /// A value that makes ``PerCallMountTool`` run to completion.
    private static let synchronousValue = "list"

    /// The value of the synchronous call that starts a nested run.
    private static let nestedValue = "nested"

    /// How many grace periods of the tool the clock moves while the slow
    /// synchronous call works.
    private static let slowWorkWindows: Double = 3

    /// Runs a call in the background when its `value` is ``backgroundValue``,
    /// and to completion for each other value. It declares no tool mount.
    /// Each call opens `started`, then works until `work` opens.
    private struct PerCallMountTool: Tool, BackgroundTool {
        let name = "per_call_mount_tool"
        let description = "starts a run for one value, and answers in band for each other value"

        /// The gate that the work of each call waits for.
        let work: RunLatch

        /// Opens when a call starts its work.
        let started: RunLatch

        /// The grace of the tool. `0` answers with the pending envelope at
        /// once.
        let grace: TimeInterval

        var inlineSettleGrace: TimeInterval { grace }

        /// A tool whose work ends at once, with grace `0`.
        ///
        /// - Returns: The tool.
        static func instant() -> PerCallMountTool {
            let work = RunLatch()
            work.open()
            return PerCallMountTool(work: work, started: RunLatch(), grace: 0)
        }

        func mount(for arguments: GeneratedContent) -> ToolMount? {
            let value = try? arguments.value(String.self, forProperty: "value")
            return value == PerCallMountTests.backgroundValue ? ToolMount(mode: .background) : .synchronous
        }

        func call(arguments: MountArguments) async throws -> String {
            started.open()
            await work.waitUntilOpen()
            return Self.output(for: arguments.value)
        }

        /// The output of this tool for `value`.
        static func output(for value: String) -> String {
            "per call: \(value)"
        }
    }

    /// In a synchronous call, mounts ``MountFixtures/GatedTool`` as background
    /// on the context of the call, and returns the envelope of the nested
    /// call.
    private struct NestedBackgroundTool: Tool {
        let name = "nested_background_tool"
        let description = "starts a nested background run from a synchronous call"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let nested = context.mount(Fixtures.GatedTool(gate: gate), as: ToolMount(mode: .background))
            return try await nested.call(arguments: arguments)
        }
    }

    /// Mounts `tool` on a new session with `configuration`, as a host does.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - configuration: The mount of the host.
    ///   - runPlane: The run plane of the session. The default is a new run
    ///     plane on the real clock.
    /// - Returns: The mounted tool, the run plane and the sink of the session.
    private static func mountOnNewSession(
        _ tool: any Tool<MountArguments, String>,
        as configuration: ToolMount,
        runPlane: RunPlane = RunPlane()
    ) throws -> (mounted: any Tool<MountArguments, String>, runPlane: RunPlane, sink: Fixtures.RecordingSink) {
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: tool, site: Fixtures.site(runPlane: runPlane, sink: sink), configuration: configuration)
        let mounted = try #require(wrapped as? any Tool<MountArguments, String>)
        return (mounted, runPlane, sink)
    }

    @Test("under a synchronous host mount, the tool starts a background run for one value and answers in band for another")
    func eachCallGetsTheMountOfItsArguments() async throws {
        let session = try Self.mountOnNewSession(PerCallMountTool.instant(), as: .synchronous)

        let started = try await session.mounted.call(arguments: MountArguments(value: Self.backgroundValue))
        let envelope = try Fixtures.decodeEnvelope(started)
        #expect(envelope.isPending)
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
        #expect(terminal.detail == PerCallMountTool.output(for: Self.backgroundValue))

        let listed = try await session.mounted.call(arguments: MountArguments(value: Self.synchronousValue))
        #expect(listed == PerCallMountTool.output(for: Self.synchronousValue))
        // Only the background call is a run on the run plane.
        #expect(await session.runPlane.settledRunTokens() == [envelope.completionToken])
    }

    @Test("under a background host mount, a synchronous call returns its real output also when it works longer than the grace")
    func synchronousCallReturnsItsOutputPastTheGrace() async throws {
        let clock = ManualRunClock()
        let work = RunLatch()
        let started = RunLatch()
        let tool = PerCallMountTool(work: work, started: started, grace: Fixtures.shortInterval)
        let session = try Self.mountOnNewSession(tool, as: ToolMount(mode: .background), runPlane: RunPlane(clock: clock))
        let mounted = session.mounted

        let calling = Task { try await mounted.call(arguments: MountArguments(value: Self.synchronousValue)) }
        await Waits.untilFirstEnds({ await started.waitUntilOpen() }, { _ = await calling.result })

        // The call works for longer than the grace of the tool: a
        // synchronous call waits on no settle period.
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(Fixtures.shortInterval * Self.slowWorkWindows))
        work.open()
        let listed = try await calling.value

        #expect(listed == PerCallMountTool.output(for: Self.synchronousValue))
        #expect(await session.runPlane.backgroundRuns().isEmpty)
        #expect(await session.runPlane.settledRunTokens().isEmpty)
    }

    @Test("a background call with grace 0 returns a pending token also when its work ends at once")
    func backgroundCallReturnsATokenForInstantWork() async throws {
        let session = try Self.mountOnNewSession(PerCallMountTool.instant(), as: .synchronous)

        let started = try await session.mounted.call(arguments: MountArguments(value: Self.backgroundValue))

        let envelope = try Fixtures.decodeEnvelope(started)
        #expect(envelope.isPending)
        #expect(PendingRunEnvelope.makeDecoded(fromRendered: started) != nil)
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
    }

    @Test("a background mount from inside a synchronous call posts its terminal to the session sink under its own token")
    func nestedBackgroundRunPostsItsTerminalToTheSessionSink() async throws {
        let gate = RunLatch()
        let session = try Self.mountOnNewSession(NestedBackgroundTool(gate: gate), as: .synchronous)

        let started = try await session.mounted.call(arguments: MountArguments(value: Self.nestedValue))
        let envelope = try Fixtures.decodeEnvelope(started)
        #expect(envelope.isPending)

        // The synchronous call returned before the nested run ends.
        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: session.runPlane)
        #expect(terminal.detail == "gated: \(Self.nestedValue)")

        // The sink of the session got the terminal as the terminal of the
        // nested run, not of the synchronous call.
        let terminals = await session.sink.events.filter { $0.kind == .completed }
        #expect(terminals.map(\.correlationID) == [envelope.completionToken])
        #expect(terminals.map(\.detail) == [terminal.detail])
        #expect(terminals.map(\.tool) == [Fixtures.GatedTool(gate: gate).name])
    }
}
