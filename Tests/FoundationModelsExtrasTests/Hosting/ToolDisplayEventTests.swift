@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// The display lane of a tool: ``ToolContext/post(display:)`` stamps each
/// ``ToolDisplayEvent`` with the run, the sink gets it in
/// ``OperationEventSink/post(display:)``, and no display event goes in the
/// lane of the model.
@Suite("ToolDisplayEvent: the display-only event lane of a tool", .timeLimit(.minutes(1)))
struct ToolDisplayEventTests {
    private typealias Fixtures = MountFixtures

    /// The tool and the op of each context that ``makeContext(sink:completionToken:)``
    /// makes.
    private static let demoToolName = "display_demo_tool"

    /// One kind of each case, with each field set.
    private static let kindOfEachCase: [ToolDisplayEvent.Kind] = [
        .contentChunk(.diff(path: "Sources/App.swift", oldText: "let a = 1", newText: "let a = 2")),
        .contentReplace([.text("line one"), .json(#"{"files":2}"#)]),
        .metadata(
            title: "Edit App.swift",
            kind: .edit,
            locations: [ToolDisplayEvent.Location(path: "Sources/App.swift", line: 3)],
            rawInput: #"{"path":"Sources/App.swift"}"#
        ),
    ]

    /// A context bound to `sink`, with ``demoToolName`` as its tool and op.
    ///
    /// - Parameters:
    ///   - sink: The sink of the context.
    ///   - completionToken: The completion token of the run.
    /// - Returns: The context.
    private static func makeContext(sink: any OperationEventSink, completionToken: String) -> ToolContext {
        ToolContext(
            sessionID: ULID(),
            runPlane: RunPlane(),
            sink: sink,
            tool: demoToolName,
            op: demoToolName,
            completionToken: completionToken,
            isCancelled: { false }
        )
    }

    /// Posts one display event, then waits on its gate.
    private struct GatedDisplayTool: Tool {
        let name = "gated_display_tool"
        let description = "posts one display event, then blocks until its gate opens"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await ToolContext.current?.post(display: .contentChunk(.text(arguments.value)))
            await gate.waitUntilOpen()
            return "gated display: \(arguments.value)"
        }
    }

    // MARK: - Stamps

    @Test("post(display:) gives the sink the kind with the tool, the op and the completion token of the run",
          arguments: kindOfEachCase)
    func postDisplayStampsTheRun(kind: ToolDisplayEvent.Kind) async throws {
        let sink = Fixtures.RecordingSink()
        let completionToken = RunPlane.makeCompletionToken()
        let context = Self.makeContext(sink: sink, completionToken: completionToken)

        await context.post(display: kind)

        let expected = ToolDisplayEvent(
            tool: Self.demoToolName, op: Self.demoToolName, correlationID: completionToken, kind: kind)
        #expect(await sink.displays == [expected])
    }

    @Test("post(display:) posts no operation event, so nothing goes in front of the model")
    func postDisplayPostsNoOperationEvent() async throws {
        let sink = Fixtures.RecordingSink()
        let context = Self.makeContext(sink: sink, completionToken: RunPlane.makeCompletionToken())

        await context.post(display: .contentChunk(.text("for the client only")))

        #expect(await sink.events.isEmpty)
    }

    @Test("two display events reach the sink as two events, in post order: the lane combines nothing")
    func displayEventsAreNotCombined() async throws {
        let sink = Fixtures.RecordingSink()
        let completionToken = RunPlane.makeCompletionToken()
        let funnel = RunEventFunnel(upstream: sink, runPlane: RunPlane(), completionToken: completionToken)
        let context = Self.makeContext(sink: funnel, completionToken: completionToken)

        await context.post(display: .contentChunk(.text("first")))
        await context.post(display: .contentChunk(.text("second")))

        let kinds = await sink.displays.map(\.kind)
        #expect(kinds == [.contentChunk(.text("first")), .contentChunk(.text("second"))])
    }

    // MARK: - The run route

    @Test("a display event of a run reaches the sink under the token of the run, and the run stages no event")
    func runDisplayReachesTheSinkAndStagesNoEvent() async throws {
        let sink = Fixtures.RecordingSink()
        let arguments = MountArguments(value: "chunk")
        let run = Fixtures.toolRun(wrapping: Fixtures.DisplayOnceTool(), arguments: arguments, sink: sink)

        await run.open()
        _ = await run.execute(arguments: arguments)

        let displays = await sink.displays
        #expect(displays.map(\.correlationID) == [run.context.completionToken])
        #expect(displays.map(\.kind) == [.contentChunk(.text("chunk"))])
        // A silent success posts no terminal, and the display event is not an
        // operation event, so the host stages nothing for the model.
        #expect(await sink.events.isEmpty)
    }

    @Test("a display event of a background run does not change the progress detail that the model reads")
    func backgroundDisplayLeavesTheProgressDetail() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(wrapping: GatedDisplayTool(gate: gate))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "chunk"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        try await AwaitedCondition.wait { await !harness.sink.displays.isEmpty }

        #expect(await harness.sink.displays.map(\.correlationID) == [envelope.completionToken])
        #expect(await harness.runPlane.backgroundRuns().map(\.latestProgressDetail) == [nil])
        // The only operation event is the pending envelope of the runner. The
        // display event added no event for the model.
        #expect(await harness.sink.events.map(\.detail) == [rendered])

        gate.open()
        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
    }
}
