import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

/// A sink as a caller outside this package writes it: a conformance to the
/// public ``OperationEventSink`` in a file with a plain import. It keeps each
/// event in post order.
actor PublicSurfaceRecordingSink: OperationEventSink {
    /// Each event, in post order.
    private(set) var events: [OperationEvent] = []

    /// Keeps `event`.
    ///
    /// - Parameter event: The event to keep.
    func post(event: OperationEvent) {
        events.append(event)
    }
}

/// Holds the tool-hosting API that a host uses to the public surface: the
/// ``RunPlane`` of a session, ``MountSite`` and ``ToolMounting``,
/// ``ToolFailureDelivery``, ``ToolDecorator``, ``PendingRunEnvelope`` and a
/// ``ToolContext`` that the host makes.
///
/// The import is plain, with no `@testable`. When a member loses `public`,
/// this file does not compile.
@Suite("Tool hosting over a plain import", .timeLimit(.minutes(1)))
struct ToolHostingPublicSurfaceTests {
    /// The grace of the inline tool, in seconds. The tool returns at once, so
    /// its run settles in this time.
    private static let inlineGraceSeconds: TimeInterval = 30

    /// The number of boundaries that the decorator test sends.
    private static let boundaryCount = 2

    // MARK: - Fixtures

    /// The arguments of the fixture tools.
    @Generable
    struct ProbeArguments {
        /// The value that the model sends.
        let value: String
    }

    /// A sink that keeps each event, in post order.
    private typealias RecordingSink = PublicSurfaceRecordingSink

    /// Keeps the terminal event of each run that settles by itself.
    private actor TerminalRecorder: BackgroundRunSettlementObserver {
        /// Each terminal event, in settlement order.
        private(set) var terminals: [OperationEvent] = []

        func deliver(settledTerminal terminal: OperationEvent) {
            terminals.append(terminal)
        }
    }

    /// Declares a background mount, waits on its gate, then returns.
    private struct GatedBackgroundTool: Tool, BackgroundTool {
        let name = "gated_background_tool"
        let description = "declares background and returns when its gate opens"
        let gate: RunLatch

        var mount: ToolMount? { ToolMount(mode: .background) }

        func call(arguments: ProbeArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "gated: \(arguments.value)"
        }
    }

    /// Declares a background mount and a grace, and returns at once, so the
    /// call answers with the output of the tool.
    private struct InlineTool: Tool, BackgroundTool {
        let name = "inline_tool"
        let description = "declares a grace and returns at once"

        var mount: ToolMount? { ToolMount(mode: .background) }

        var inlineSettleGrace: TimeInterval { ToolHostingPublicSurfaceTests.inlineGraceSeconds }

        func call(arguments: ProbeArguments) async throws -> String {
            "inline: \(arguments.value)"
        }
    }

    /// Asks one question, then returns the action of the answer.
    private struct ElicitingTool: Tool {
        let name = "eliciting_tool"
        let description = "asks one question, then returns the action of the answer"
        let request: ElicitationRequest

        func call(arguments: ProbeArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await context.elicit(request).action.rawValue
        }
    }

    /// The error of ``ThrowingTool``.
    private struct ProbeFailure: Error {}

    /// Throws at once.
    private struct ThrowingTool: Tool {
        let name = "throwing_tool"
        let description = "throws at once"

        func call(arguments: ProbeArguments) async throws -> String {
            throw ProbeFailure()
        }
    }

    /// Counts each boundary.
    private actor BoundaryCounter {
        /// The number of boundaries.
        private(set) var count = 0

        /// Adds one boundary.
        func increment() {
            count += 1
        }
    }

    /// A tool that counts each boundary.
    private struct CountingTool: SubmissionBoundaryTool {
        let name = "counting_tool"
        let description = "counts each submissionWillBegin() call"
        let counter: BoundaryCounter

        func submissionWillBegin() async {
            await counter.increment()
        }

        func call(arguments: ProbeArguments) async throws -> String {
            arguments.value
        }
    }

    /// A decorator as a host outside this package writes it. It declares no
    /// `submissionWillBegin()`: the ``ToolDecorator`` extension gives it.
    private struct ForwardingDecorator: SubmissionBoundaryTool, ToolDecorator {
        let wrapped: CountingTool

        var name: String { wrapped.name }
        var description: String { wrapped.description }

        func call(arguments: ProbeArguments) async throws -> String {
            try await wrapped.call(arguments: arguments)
        }
    }

    // MARK: - Harness

    /// Mounts `tool` on `runPlane`, as a host does.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the session.
    ///   - inlineSettleGrace: The settle period of the session. The default
    ///     is `0`, so a background call answers with its pending envelope at
    ///     once.
    /// - Returns: The mounted tool, typed.
    /// - Throws: When the mounted tool does not keep the types of `tool`.
    private static func mount(
        _ tool: any Tool,
        on runPlane: RunPlane,
        sink: any OperationEventSink = RecordingSink(),
        inlineSettleGrace: TimeInterval = 0
    ) throws -> any Tool<ProbeArguments, String> {
        let site = MountSite(sessionID: ULID(), runPlane: runPlane, sink: sink, inlineSettleGrace: inlineSettleGrace)
        let mounted = ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous)
        return try #require(mounted as? any Tool<ProbeArguments, String>)
    }

    /// The envelope of one call of `tool`.
    ///
    /// - Parameter rendered: The output of the call.
    /// - Returns: The envelope.
    /// - Throws: When the output is not an envelope.
    private static func envelope(of rendered: String) throws -> PendingRunEnvelope {
        try #require(PendingRunEnvelope.makeDecoded(fromRendered: rendered))
    }

    /// A form question with one Boolean field.
    private static func formRequest() -> ElicitationRequest {
        ElicitationRequest(
            message: "Proceed?",
            elicitationId: ULID(),
            requestedSchema: ElicitationRequestedSchema(properties: ["ok": .boolean(ElicitationBooleanSchema())])
        )
    }

    /// Waits until `sink` holds the elicitation event of `request`. The run
    /// posts that event after the run plane holds the elicitation.
    private static func waitUntilPending(_ request: ElicitationRequest, in sink: RecordingSink) async throws {
        try await AwaitedCondition.wait {
            await sink.events.contains { $0.elicitation?.elicitationId == request.elicitationId }
        }
    }

    /// Starts a call of a gated background tool on `runPlane`.
    ///
    /// - Parameters:
    ///   - gate: The gate of the run.
    ///   - runPlane: The run plane of the session.
    /// - Returns: The completion token of the run.
    private static func startGatedRun(gate: RunLatch, on runPlane: RunPlane) async throws -> String {
        let mounted = try mount(GatedBackgroundTool(gate: gate), on: runPlane)
        let rendered = try await mounted.call(arguments: ProbeArguments(value: "run"))
        let pending = try envelope(of: rendered)
        #expect(pending.pending)
        return pending.completionToken
    }

    // MARK: - The run plane

    @Test("the run plane tracks a background run, and gives its terminal event to the observer when it settles")
    func theRunPlaneTracksARunAndTellsTheObserver() async throws {
        let runPlane = RunPlane()
        let observer = TerminalRecorder()
        await runPlane.attach(settlementObserver: observer)
        let gate = RunLatch.closed()

        let token = try await Self.startGatedRun(gate: gate, on: runPlane)
        #expect(await runPlane.backgroundRuns().map(\.completionToken) == [token])
        #expect(await runPlane.settledRunTokens().isEmpty)

        gate.open()
        try await AwaitedCondition.wait { await !observer.terminals.isEmpty }

        let terminal = try #require(await observer.terminals.first)
        #expect(terminal.correlationID == token)
        #expect(terminal.detail == "gated: run")
        #expect(await runPlane.backgroundRuns().isEmpty)
        #expect(await runPlane.settledRunTokens() == [token])
    }

    @Test("the sweep stops each open run and gives one terminal event for each")
    func theSweepStopsEachOpenRun() async throws {
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let token = try await Self.startGatedRun(gate: gate, on: runPlane)

        let terminals = await runPlane.sweep()
        gate.open()

        #expect(terminals.map(\.correlationID) == [token])
        #expect(terminals.first?.outcome == .cancelled)
        #expect(await runPlane.backgroundRuns().isEmpty)
    }

    @Test("a completion token of the run plane is a ULID string")
    func aCompletionTokenIsAULIDString() {
        #expect(ULID(ulidString: RunPlane.makeCompletionToken()) != nil)
    }

    // MARK: - Elicitation

    @Test("respond gives the answer of the user to the run that asked")
    func respondGivesTheAnswerToTheRun() async throws {
        let runPlane = RunPlane()
        let sink = RecordingSink()
        let request = Self.formRequest()
        let mounted = try Self.mount(ElicitingTool(request: request), on: runPlane, sink: sink)
        let asking = Task { try await mounted.call(arguments: ProbeArguments(value: "ask")) }

        try await Self.waitUntilPending(request, in: sink)
        let delivery = await runPlane.respond(elicitationId: request.elicitationId, .decline)

        #expect(delivery == .delivered)
        #expect(try await asking.value == ElicitationResponse.Action.decline.rawValue)
        #expect(await runPlane.respond(elicitationId: request.elicitationId, .decline) == .noPendingElicitation)
    }

    @Test("an accepted URL elicitation waits for complete, and then resumes the run")
    func anAcceptedURLElicitationWaitsForComplete() async throws {
        let runPlane = RunPlane()
        let sink = RecordingSink()
        let request = ElicitationRequest(
            message: "Sign in",
            elicitationId: ULID(),
            url: try #require(URL(string: "https://example.com/sign-in"))
        )
        let mounted = try Self.mount(ElicitingTool(request: request), on: runPlane, sink: sink)
        let asking = Task { try await mounted.call(arguments: ProbeArguments(value: "ask")) }

        try await Self.waitUntilPending(request, in: sink)
        let accepted = await runPlane.respond(elicitationId: request.elicitationId, .accept(content: nil))
        let completed = await runPlane.complete(elicitationId: request.elicitationId)

        #expect(accepted == .acceptedAwaitingCompletion)
        #expect(completed == .completed)
        #expect(try await asking.value == ElicitationResponse.Action.accept.rawValue)
        #expect(await runPlane.complete(elicitationId: request.elicitationId) == .noPendingElicitation)
    }

    // MARK: - A context that the host makes

    @Test("a context that the host makes binds with $current and stamps each event")
    func aContextThatTheHostMakesStampsEachEvent() async throws {
        let sink = RecordingSink()
        let token = ToolContext.makeCompletionToken()
        let context = ToolContext(
            sessionID: ULID(),
            runPlane: RunPlane(),
            sink: sink,
            tool: "host_tool",
            op: "run host",
            completionToken: token,
            isCancelled: { false }
        )

        await ToolContext.$current.withValue(context) {
            await ToolContext.current?.progress("halfway")
        }

        let event = try #require(await sink.events.first)
        #expect(event.tool == "host_tool")
        #expect(event.op == "run host")
        #expect(event.correlationID == token)
        #expect(event.detail == "halfway")
    }

    // MARK: - Failure delivery and decorators

    @Test("the failure decorator gives a failure to the model as text, and the tool beneath still throws")
    func theFailureDecoratorGivesTheFailureAsText() async throws {
        let delivering = ToolFailureDelivery.makeWrapped(tool: ThrowingTool())
        let text = try #require(delivering as? any Tool<ProbeArguments, String>)
        let beneath = try #require(ToolFailureDelivery.throwingTool(of: delivering) as? ThrowingTool)

        let output = try await text.call(arguments: ProbeArguments(value: "fail"))

        #expect(!output.isEmpty)
        await #expect(throws: ProbeFailure.self) {
            _ = try await beneath.call(arguments: ProbeArguments(value: "fail"))
        }
    }

    @Test("a decorator written outside this package passes each boundary to the tool beneath")
    func aDecoratorPassesEachBoundary() async {
        let counter = BoundaryCounter()
        let decorator = ForwardingDecorator(wrapped: CountingTool(counter: counter))

        for _ in 0..<Self.boundaryCount {
            await decorator.submissionWillBegin()
        }

        #expect(await counter.count == Self.boundaryCount)
    }

    // MARK: - The envelope

    @Test("a background call that ends inside its grace answers with the output of the tool, not an envelope")
    func aRunInsideTheGraceAnswersWithItsOwnOutput() async throws {
        let mounted = try Self.mount(InlineTool(), on: RunPlane())

        let output = try await mounted.call(arguments: ProbeArguments(value: "x"))

        #expect(output == "inline: x")
        #expect(PendingRunEnvelope.makeDecoded(fromRendered: output) == nil)
    }

    @Test("the pending envelope is always pending, and holds the completion token and the next sentence")
    func thePendingEnvelopeHoldsOnlyThePendingFields() async throws {
        let runPlane = RunPlane()
        let gate = RunLatch.closed()
        let mounted = try Self.mount(GatedBackgroundTool(gate: gate), on: runPlane, inlineSettleGrace: 0)

        let pending = try Self.envelope(of: try await mounted.call(arguments: ProbeArguments(value: "x")))

        #expect(pending.pending)
        #expect(pending.next == PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: pending.completionToken))
        gate.open()
        _ = await runPlane.sweep()
    }

    @Test("a host sets the settle period on the context, and settling(within:) changes it for inner mounts")
    func aHostSetsTheSettlePeriodOnTheContext() {
        let context = ToolContext(
            sessionID: ULID(), runPlane: RunPlane(), sink: RecordingSink(), tool: "host_tool", op: "run host",
            completionToken: ToolContext.makeCompletionToken(), isCancelled: { false },
            inlineSettleGrace: Self.inlineGraceSeconds)

        #expect(context.inlineSettleGrace == Self.inlineGraceSeconds)
        #expect(context.settling(within: 0).inlineSettleGrace == 0)
        #expect(ToolMount.defaultInlineSettleGrace > 0)
    }
}
