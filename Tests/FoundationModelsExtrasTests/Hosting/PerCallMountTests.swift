@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// ``BackgroundTool/mount(for:)``: one tool runs some calls in the background
/// and other calls to completion, and the tool chooses for each call.
@Suite("Per-call mount: a tool chooses background or synchronous for each call", .timeLimit(.minutes(1)))
struct PerCallMountTests {
    private typealias Fixtures = MountFixtures

    /// The value that makes ``PerCallMountTool`` start a background run.
    private static let backgroundValue = "start"

    /// A value that makes ``PerCallMountTool`` run to completion.
    private static let synchronousValue = "list"

    /// The value of the synchronous call that starts a nested run.
    private static let nestedValue = "nested"

    /// How many ``MountFixtures/shortInterval`` windows the slow synchronous
    /// call works: longer than the grace of the tool.
    private static let slowWorkWindows: Double = 3

    /// Runs a call in the background when its `value` is ``backgroundValue``,
    /// and to completion for each other value. It declares no tool mount.
    private struct PerCallMountTool: Tool, BackgroundTool {
        let name = "per_call_mount_tool"
        let description = "starts a run for one value, and answers in band for each other value"

        /// How long each call works, in seconds.
        let workSeconds: TimeInterval

        /// The grace of the tool. `0` answers with the pending envelope at
        /// once.
        let grace: TimeInterval

        var inlineSettleGrace: TimeInterval { grace }

        func mount(for arguments: GeneratedContent) -> ToolMount? {
            let value = try? arguments.value(String.self, forProperty: "value")
            return value == PerCallMountTests.backgroundValue ? ToolMount(mode: .background) : .synchronous
        }

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(for: .seconds(workSeconds))
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
    /// - Returns: The mounted tool, the run plane and the sink of the session.
    private static func mountOnNewSession(
        _ tool: any Tool<MountArguments, String>,
        as configuration: ToolMount
    ) throws -> (mounted: any Tool<MountArguments, String>, runPlane: RunPlane, sink: Fixtures.RecordingSink) {
        let runPlane = RunPlane()
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: tool, site: Fixtures.site(runPlane: runPlane, sink: sink), configuration: configuration)
        let mounted = try #require(wrapped as? any Tool<MountArguments, String>)
        return (mounted, runPlane, sink)
    }

    @Test("under a synchronous host mount, the tool starts a background run for one value and answers in band for another")
    func eachCallGetsTheMountOfItsArguments() async throws {
        let session = try Self.mountOnNewSession(PerCallMountTool(workSeconds: 0, grace: 0), as: .synchronous)

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
        let tool = PerCallMountTool(
            workSeconds: Fixtures.shortInterval * Self.slowWorkWindows, grace: Fixtures.shortInterval)
        let session = try Self.mountOnNewSession(tool, as: ToolMount(mode: .background))

        let listed = try await session.mounted.call(arguments: MountArguments(value: Self.synchronousValue))

        #expect(listed == PerCallMountTool.output(for: Self.synchronousValue))
        #expect(await session.runPlane.backgroundRuns().isEmpty)
        #expect(await session.runPlane.settledRunTokens().isEmpty)
    }

    @Test("a background call with grace 0 returns a pending token also when its work ends at once")
    func backgroundCallReturnsATokenForInstantWork() async throws {
        let session = try Self.mountOnNewSession(PerCallMountTool(workSeconds: 0, grace: 0), as: .synchronous)

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
