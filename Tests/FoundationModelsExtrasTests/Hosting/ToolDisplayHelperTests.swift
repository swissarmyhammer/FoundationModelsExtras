@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// The two display helpers of ``ToolContext``: ``ToolContext/emit(chunk:)``
/// and ``ToolContext/update(title:kind:locations:)``.
///
/// Each runner path gives the display events to the sink under the token of
/// the run. A background run sends them also after its settle period. A run
/// that answers in its settle period keeps them: the runner does not withdraw
/// a display event. Each display event starts the timeout of the run again.
@Suite("ToolContext.emit(chunk:) and update(title:kind:locations:): the display helpers of a tool")
struct ToolDisplayHelperTests {
    private typealias Fixtures = MountFixtures

    /// The value of each call. Each fixture tool uses it as the path of the
    /// location and as the text of the chunk.
    private static let callValue = "notes.txt"

    /// The title that each fixture tool sends.
    private static let title = "Read the notes"

    /// The output of a fixture tool that runs with no bound context.
    private static let unboundOutput = "unbound"

    /// The number of beats of ``DisplayBeatTool``.
    private static let beatCount = 8

    /// The timeout, in seconds of the manual clock, that the beats start
    /// again. The full run is longer.
    private static let beatTimeout: TimeInterval = 10

    /// The display events that a fixture tool sends for ``callValue``, in
    /// order, under `token`.
    ///
    /// - Parameters:
    ///   - tool: The name of the tool. It is also the op of the run.
    ///   - token: The completion token of the run.
    /// - Returns: The metadata event, then the chunk event.
    private static func expectedDisplays(tool: String, token: String) -> [ToolDisplayEvent] {
        let metadata = ToolDisplayEvent.Kind.metadata(
            title: title, kind: .read, locations: [ToolDisplayEvent.Location(path: callValue)], rawInput: nil)
        return [
            ToolDisplayEvent(tool: tool, op: tool, correlationID: token, kind: metadata),
            ToolDisplayEvent(tool: tool, op: tool, correlationID: token, kind: .contentChunk(.text(callValue))),
        ]
    }

    /// Sends the metadata and one chunk for `value` through the context of
    /// the current call.
    ///
    /// - Parameter value: The path of the location and the text of the chunk.
    private static func sendDisplays(for value: String) async {
        let context = ToolContext.current
        await context?.update(title: title, kind: .read, locations: [ToolDisplayEvent.Location(path: value)])
        await context?.emit(chunk: .text(value))
    }

    // MARK: - Fixture tools

    /// Waits on its gate, sends the metadata and one chunk, then returns the
    /// completion token of its run.
    private struct DisplayingTool: Tool {
        let name = "displaying_tool"
        let description = "waits on its gate, sends display events, then returns its completion token"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            await ToolDisplayHelperTests.sendDisplays(for: arguments.value)
            return ToolContext.current?.completionToken ?? ToolDisplayHelperTests.unboundOutput
        }
    }

    /// Sends the metadata and one chunk, then returns the completion token of
    /// its call as an output that is not `String`.
    private struct DisplayingNonStringTool: Tool {
        let name = "displaying_non_string_tool"
        let description = "sends display events, then returns its completion token as a non-String output"

        func call(arguments: MountArguments) async throws -> NonStringToolOutput {
            await ToolDisplayHelperTests.sendDisplays(for: arguments.value)
            return NonStringToolOutput(
                text: ToolContext.current?.completionToken ?? ToolDisplayHelperTests.unboundOutput)
        }
    }

    /// The display helper that ``DisplayBeatTool`` calls on each beat.
    enum DisplayBeat: CaseIterable, Sendable {
        /// Each beat calls ``ToolContext/emit(chunk:)``.
        case chunk

        /// Each beat calls ``ToolContext/update(title:kind:locations:)``.
        case metadata
    }

    /// Sends one display event when each of its gates opens, in order, and no
    /// progress, then returns.
    private struct DisplayBeatTool: Tool {
        /// The output of the tool when each beat was sent.
        static let output = "display beats done"

        let name = "display_beat_tool"
        let description = "sends one display event for each gate that opens, then returns"
        let beat: DisplayBeat

        /// The gate of each beat, in order.
        let gates: [RunLatch]

        func call(arguments: MountArguments) async throws -> String {
            for (index, gate) in gates.enumerated() {
                await gate.waitUntilOpen()
                await send(beatNumber: index)
            }
            return Self.output
        }

        /// Sends the display event of beat `beatNumber`.
        private func send(beatNumber: Int) async {
            let context = ToolContext.current
            let text = "beat \(beatNumber)"
            switch beat {
            case .chunk:
                await context?.emit(chunk: .text(text))
            case .metadata:
                await context?.update(title: text)
            }
        }
    }

    // MARK: - Each runner path

    @Test("ContextBindingTool: emit and update reach the sink under the token of the call, and post no operation event")
    func contextBindingToolDeliversTheDisplays() async throws {
        let sink = Fixtures.RecordingSink()
        let bound = ContextBindingTool(
            wrapping: DisplayingNonStringTool(), site: Fixtures.site(runPlane: RunPlane(), sink: sink))

        let output = try await bound.call(arguments: MountArguments(value: Self.callValue))

        #expect(await sink.displays == Self.expectedDisplays(tool: bound.name, token: output.text))
        #expect(await sink.events.isEmpty)
    }

    @Test("RunToCompletionRunner: emit and update reach the sink under the token of the run, and post no operation event")
    func runToCompletionRunnerDeliversTheDisplays() async throws {
        let gate = RunLatch()
        gate.open()
        let harness = Fixtures.runToCompletionHarness(wrapping: DisplayingTool(gate: gate))

        let token = try await harness.mounted.call(arguments: MountArguments(value: Self.callValue))

        #expect(await harness.sink.displays == Self.expectedDisplays(tool: harness.mounted.name, token: token))
        #expect(await harness.sink.events.isEmpty)
    }

    @Test("BackgroundToolRunner: a run that ends in its settle period sends emit and update under the token of the run")
    func backgroundToolRunnerDeliversTheDisplaysInTheSettlePeriod() async throws {
        let gate = RunLatch()
        gate.open()
        let harness = Fixtures.backgroundHarness(
            wrapping: DisplayingTool(gate: gate), inlineSettleGrace: Fixtures.generousInterval)

        let token = try await harness.mounted.call(arguments: MountArguments(value: Self.callValue))

        #expect(!PendingRunEnvelope.isRendered(text: token))
        #expect(await harness.sink.displays == Self.expectedDisplays(tool: harness.mounted.name, token: token))
    }

    @Test("BackgroundToolRunner: a run that continues after its settle period still sends emit and update under its token")
    func backgroundToolRunnerDeliversTheDisplaysAfterTheSettlePeriod() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(
            wrapping: DisplayingTool(gate: gate), inlineSettleGrace: Fixtures.pendingAtOnceGrace)

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: Self.callValue))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.isPending)
        #expect(await harness.sink.displays.isEmpty)

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)

        #expect(terminal.detail == envelope.completionToken)
        #expect(
            await harness.sink.displays
                == Self.expectedDisplays(tool: harness.mounted.name, token: envelope.completionToken))
        // The display events add no operation event: only the pending
        // progress and the terminal event go to the model.
        #expect(await harness.sink.events.map(\.kind) == [.progress, .completed])
    }

    // MARK: - The settle period

    @Test("a run that answers in its settle period keeps its display events: the sink has them before the withdraw, and the withdraw takes back only the staged operation events")
    func inlineAnswerDoesNotWithdrawTheDisplays() async throws {
        let sink = Fixtures.StagingSink()
        let gate = RunLatch()
        gate.open()
        let runner = BackgroundToolRunner(
            wrapping: DisplayingTool(gate: gate),
            site: Fixtures.site(runPlane: RunPlane(), sink: sink, inlineSettleGrace: Fixtures.generousInterval),
            timeout: nil)

        let token = try await runner.call(arguments: MountArguments(value: Self.callValue))

        let expected = Self.expectedDisplays(tool: runner.name, token: token)
        #expect(await sink.staged.isEmpty)
        #expect(await sink.displayCountAtWithdraw == expected.count)
        #expect(await sink.recording.displays == expected)
    }

    // MARK: - The timeout

    @Test("a display event starts the timeout again: a tool that sends display events faster than the timeout runs past it",
          arguments: DisplayBeat.allCases)
    func displayEventResetsTheTimeout(beat: DisplayBeat) async throws {
        let gates = (0..<Self.beatCount).map { _ in RunLatch() }
        let clock = ManualRunClock()
        let sink = Fixtures.RecordingSink()
        let mounted = RunToCompletionRunner(
            wrapping: DisplayBeatTool(beat: beat, gates: gates),
            site: Fixtures.site(runPlane: RunPlane(clock: clock), sink: sink),
            timeout: Self.beatTimeout)
        let calling = Task { try await mounted.call(arguments: MountArguments(value: Self.callValue)) }

        // Each beat comes in the middle of a window, and each window ends
        // after the beat. The whole run is longer than one timeout.
        for (index, gate) in gates.enumerated() {
            await clock.waitForSleepers(atLeast: 1) { _ = await calling.result }
            clock.advance(by: .seconds(Self.beatTimeout / 2))
            gate.open()
            await Waits.untilFirstEnds(
                { _ = await sink.displayLog.waitUntil { $0.count > index } }, { _ = await calling.result })
            clock.advance(by: .seconds(Self.beatTimeout / 2))
        }

        let output = try await calling.value
        #expect(output == DisplayBeatTool.output)
        #expect(await sink.displays.count == Self.beatCount)
    }
}
