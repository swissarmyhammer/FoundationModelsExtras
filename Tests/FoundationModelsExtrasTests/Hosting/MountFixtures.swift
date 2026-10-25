@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import Tracing
import ULID

/// The arguments of each mount fixture tool.
@Generable
struct MountArguments {
    /// A value that the tool echoes back.
    let value: String
}

/// The fixtures that the runner suites share.
enum MountFixtures {
    // MARK: - Intervals

    /// A timeout or a hold that keeps a suite fast, but that a fixture never
    /// elapses by accident.
    static let shortInterval: TimeInterval = 0.2

    /// A deadline that a test treats as "never elapses".
    static let generousInterval: TimeInterval = 30

    // MARK: - Telemetry of a background call

    /// The span names of one background call whose run settled, sorted: the
    /// tool span, which ends when the call returns, and the run span, which
    /// ends when the run body returns. The two spans can end in each order.
    static let spanNamesOfASettledBackgroundCall = [ExtrasTelemetry.SpanName.tool, ExtrasTelemetry.SpanName.run]
        .sorted()

    /// The tool-call metric labels of one call, sorted: the count and the
    /// duration.
    static let metricLabelsOfOneToolCall = [
        ExtrasTelemetry.MetricName.toolCalls,
        ExtrasTelemetry.MetricName.toolDuration,
    ].sorted()

    /// The queue metric labels of one queue whose tasks completed, sorted:
    /// the depth, the wait time, the run time and the count.
    static let metricLabelsOfOneQueue = [
        ExtrasTelemetry.MetricName.queueDepth,
        ExtrasTelemetry.MetricName.queueWait,
        ExtrasTelemetry.MetricName.queueRun,
        ExtrasTelemetry.MetricName.queueTasks,
    ].sorted()

    /// The metric labels of one run-to-completion call that sends its
    /// terminal event upstream, sorted: the tool-call metrics, and the queue
    /// metrics of the delivery on the `tool_events` queue. A call that fails
    /// or times out sends its terminal event. A silent success sends no event.
    static let metricLabelsOfACallThatSendsItsTerminal = (metricLabelsOfOneToolCall + metricLabelsOfOneQueue).sorted()

    /// The metric labels of one background call whose run settled, sorted:
    /// the tool-call metrics of the start, the queue metrics of the run on
    /// the `run_plane` queue, and the queue metrics of the event deliveries of
    /// the run on the `tool_events` queue.
    static let metricLabelsOfASettledBackgroundCall =
        (metricLabelsOfOneToolCall + metricLabelsOfOneQueue + metricLabelsOfOneQueue).sorted()

    // MARK: - Sink

    /// A sink that keeps each event, each display event and each report, in
    /// order. A test waits on ``eventLog`` or ``displayLog`` for a post, with
    /// no poll.
    actor RecordingSink: OperationEventSink, ToolCallReportSink {
        /// Each event, in post order.
        nonisolated let eventLog = Recorder<OperationEvent>()

        /// Each display event, in post order.
        nonisolated let displayLog = Recorder<ToolDisplayEvent>()

        /// Each event, in post order.
        var events: [OperationEvent] { eventLog.values }

        /// Each display event, in post order.
        var displays: [ToolDisplayEvent] { displayLog.values }

        /// Each report, in post order.
        private(set) var reports: [ToolCallReport] = []

        /// Keeps `event`.
        func post(event: OperationEvent) {
            eventLog.append(event)
        }

        /// Keeps `event`.
        ///
        /// This method is `async` on purpose. ``StagingSink`` calls it
        /// directly, from outside this actor. If this method is not `async`,
        /// that call uses the empty default of `OperationEventSink`, and the
        /// display event is lost.
        func post(display event: ToolDisplayEvent) async {
            displayLog.append(event)
        }

        /// Waits until the sink got an event that `matches`, or until the
        /// task is cancelled.
        ///
        /// - Parameter matches: Tells if an event is the event to wait for.
        nonisolated func waitForAnEvent(where matches: @escaping @Sendable (OperationEvent) -> Bool) async {
            await eventLog.waitUntil { events in events.contains(where: matches) }
        }

        /// Keeps `report`.
        func post(report: ToolCallReport) {
            reports.append(report)
        }
    }

    /// A sink that answers an elicitation when it sees the event, with no
    /// poll. The answer goes to the run plane from inside `post(event:)`, so
    /// the question ends before the post returns. When the answer is the
    /// accept of a URL question, the sink also completes the question, as a
    /// user who finishes the flow.
    actor ImmediatelyRespondingSink: OperationEventSink {
        /// The run plane that holds the elicitation.
        private let runPlane: RunPlane

        /// The answer to give.
        private let response: ElicitationResponse

        /// Makes the sink.
        ///
        /// - Parameters:
        ///   - runPlane: The run plane that holds the elicitation.
        ///   - response: The answer to give.
        init(runPlane: RunPlane, response: ElicitationResponse) {
            self.runPlane = runPlane
            self.response = response
        }

        /// Gives ``response`` to the question of `event`, when `event` is an
        /// elicitation event. Completes the question when the run plane waits
        /// for the completion of a URL accept.
        ///
        /// - Parameter event: The event.
        func post(event: OperationEvent) async {
            guard let request = event.elicitation else { return }
            let delivery = await runPlane.respond(elicitationId: request.elicitationId, response)
            guard delivery == .acceptedAwaitingCompletion else { return }
            await runPlane.complete(elicitationId: request.elicitationId)
        }
    }

    /// A sink that stages each event for a later prompt, and takes back the
    /// staged events of a run on request. It gives each display event to its
    /// ``RecordingSink``, which keeps the display events. It records how many
    /// display events the recording sink had when the runner took back the
    /// staged events of a run.
    actor StagingSink: OperationEventSink, StagedEventWithdrawing {
        /// The sink that keeps each display event. A withdraw does not touch
        /// it.
        let recording = RecordingSink()

        /// The staged events, in post order.
        private(set) var staged: [OperationEvent] = []

        /// The number of display events at the last withdraw, or `nil` before
        /// the first withdraw.
        private(set) var displayCountAtWithdraw: Int?

        /// Stages `event`.
        func post(event: OperationEvent) {
            staged.append(event)
        }

        /// Gives `event` to ``recording``.
        func post(display event: ToolDisplayEvent) async {
            await recording.post(display: event)
        }

        /// Records the display count, then removes each staged event of the
        /// run `correlationID`.
        func withdrawStagedEvents(correlationID: String) async {
            displayCountAtWithdraw = await recording.displays.count
            staged.removeAll { $0.correlationID == correlationID }
        }
    }

    /// A sink that stages each event, as ``StagingSink`` does, and records
    /// at each withdraw whether the run plane already settled the run. The
    /// settlement wakes the host, and a host whose delivery is free can take
    /// the staged events then, so a run that answers inline must take its
    /// events back before it settles.
    actor SettleWatchingSink: OperationEventSink, StagedEventWithdrawing {
        /// The run plane of the runs.
        let runPlane: RunPlane

        /// The staged events, in post order.
        private(set) var staged: [OperationEvent] = []

        /// Whether the run plane had settled the run at each withdraw, in
        /// withdraw order.
        private(set) var settledAtEachWithdraw: [Bool] = []

        /// Makes a sink for the runs of `runPlane`.
        ///
        /// - Parameter runPlane: The run plane of the runs.
        init(runPlane: RunPlane) {
            self.runPlane = runPlane
        }

        /// Stages `event`.
        func post(event: OperationEvent) {
            staged.append(event)
        }

        /// Records whether the run `correlationID` settled, then removes each
        /// staged event of that run.
        func withdrawStagedEvents(correlationID: String) async {
            settledAtEachWithdraw.append(await runPlane.settledRunTokens().contains(correlationID))
            staged.removeAll { $0.correlationID == correlationID }
        }
    }

    /// A sink that cancels the task of the call when the runner takes back
    /// the staged events of a run. The runner does that after the wait for
    /// the run settled and before it makes its answer, thus the cancel comes
    /// at a known point of the call.
    actor CallCancellingSink: OperationEventSink, StagedEventWithdrawing {
        /// Drops `event`.
        func post(event _: OperationEvent) {}

        /// Cancels the task of the call that takes back the staged events.
        func withdrawStagedEvents(correlationID _: String) {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    // MARK: - Host context

    /// The tool of each context that ``hostContext(on:sink:completionToken:)``
    /// makes.
    static let hostTool = "host_tool"

    /// The op of each context that ``hostContext(on:sink:completionToken:)``
    /// makes.
    static let hostOp = "ask user"

    /// A context that a host makes on `runPlane`, bound to `sink`. It is a run
    /// of its own, and it is never cancelled.
    ///
    /// - Parameters:
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the context.
    ///   - completionToken: The completion token of the context. A question
    ///     of the context links to it. The default is a new token.
    /// - Returns: The context.
    static func hostContext(
        on runPlane: RunPlane,
        sink: any OperationEventSink,
        completionToken: String = RunPlane.makeCompletionToken()
    ) -> ToolContext {
        ToolContext(
            sessionID: ULID(), runPlane: runPlane, sink: sink, tool: hostTool, op: hostOp,
            completionToken: completionToken, isCancelled: { false })
    }

    /// The value of each call that ``callSynchronously(_:mountedOn:)``
    /// starts.
    static let synchronousCallValue = "x"

    /// Mounts `tool` in a synchronous mount on a new site of `runPlane` that
    /// posts to a new ``SignallingSink``, and starts one call. Only the call
    /// holds the sink, thus the stream ends when the call ends.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - runPlane: The run plane of the session.
    /// - Returns: The stream of the sink, and the task of the call.
    /// - Throws: When the mounted tool does not keep the types of `tool`.
    static func callSynchronously(
        _ tool: any Tool, mountedOn runPlane: RunPlane
    ) throws -> (signals: AsyncStream<ElicitationSignal>, calling: Task<String, any Error>) {
        let sink = SignallingSink()
        let site = site(runPlane: runPlane, sink: sink)
        let mounted = try #require(
            ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous)
                as? any Tool<MountArguments, String>)
        return (
            sink.signals,
            Task { try await mounted.call(arguments: MountArguments(value: synchronousCallValue)) }
        )
    }

    // MARK: - Harness

    /// The wiring of one test: the run plane, the sink and the mounted tool.
    struct Harness<Mounted: Tool> {
        /// The run plane of the mount.
        let runPlane: RunPlane

        /// The sink of the mount.
        let sink: RecordingSink

        /// The mounted tool.
        let mounted: Mounted
    }

    /// The settle period of the fixture sites: `0`. Each background call of a
    /// fixture site answers with its pending envelope at once, so a test of
    /// the pending path does not wait. A test of the settle period states
    /// its own value.
    static let pendingAtOnceGrace: TimeInterval = 0

    /// The mount site of a new session over `runPlane` and `sink`.
    ///
    /// - Parameters:
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the session.
    ///   - inlineSettleGrace: The settle period of the site. The default is
    ///     ``pendingAtOnceGrace``.
    ///   - tracer: The tracer of the session, or `nil` for
    ///     `InstrumentationSystem.tracer` at call time. The default is `nil`.
    /// - Returns: The mount site.
    static func site(
        runPlane: RunPlane,
        sink: any OperationEventSink,
        inlineSettleGrace: TimeInterval = pendingAtOnceGrace,
        tracer: (any Tracer)? = nil
    ) -> MountSite {
        MountSite(sessionID: ULID(), runPlane: runPlane, sink: sink, tracer: tracer, inlineSettleGrace: inlineSettleGrace)
    }

    /// Mounts `tool` in a ``BackgroundToolRunner`` over a new run plane and
    /// sink.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - timeout: The timeout of the mount, or `nil` for none.
    ///   - inlineSettleGrace: The settle period of the site. The default is
    ///     ``pendingAtOnceGrace``.
    ///   - tracer: The tracer of the session, or `nil` for
    ///     `InstrumentationSystem.tracer` at call time. The default is `nil`.
    ///   - runPlane: The run plane of the mount. The default is a new run
    ///     plane on the real clock. A test of the settle period gives a run
    ///     plane on a ``ManualRunClock``.
    static func backgroundHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = nil,
        inlineSettleGrace: TimeInterval = pendingAtOnceGrace,
        tracer: (any Tracer)? = nil,
        runPlane: RunPlane = RunPlane()
    ) -> Harness<BackgroundToolRunner<Arguments>> {
        let sink = RecordingSink()
        let site = site(runPlane: runPlane, sink: sink, inlineSettleGrace: inlineSettleGrace, tracer: tracer)
        let mounted = BackgroundToolRunner(wrapping: tool, site: site, timeout: timeout)
        return Harness(runPlane: runPlane, sink: sink, mounted: mounted)
    }

    /// Mounts `tool` in a ``RunToCompletionRunner`` over a run plane and a
    /// new sink.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - timeout: The timeout of the mount, or `nil` for none.
    ///   - runPlane: The run plane of the mount. The default is a new run
    ///     plane on the real clock. A test of the timeout gives a run plane
    ///     on a ``ManualRunClock``.
    static func runToCompletionHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = nil,
        runPlane: RunPlane = RunPlane()
    ) -> Harness<RunToCompletionRunner<Arguments>> {
        let sink = RecordingSink()
        let mounted = RunToCompletionRunner(wrapping: tool, site: site(runPlane: runPlane, sink: sink), timeout: timeout)
        return Harness(runPlane: runPlane, sink: sink, mounted: mounted)
    }

    /// The run of one call, over a new run plane and `sink`. Call `open()`,
    /// then `execute(arguments:)`.
    static func toolRun<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        arguments: Arguments,
        sink: any OperationEventSink
    ) -> ToolRun<Arguments> {
        ToolRun(wrapped: tool, arguments: arguments, site: site(runPlane: RunPlane(), sink: sink), mountTimeout: nil)
    }

    // MARK: - Model-facing tool

    /// `tool` under the decorator that gives a failure to the model, as a
    /// session sees a `String` tool.
    ///
    /// - Parameters:
    ///   - tool: The `String` tool to decorate.
    ///   - arguments: The arguments type of `tool`.
    /// - Returns: The decorated text tool.
    /// - Throws: When the decorator does not keep `tool` as a text tool of
    ///   `arguments`.
    static func modelFacingTextTool<Arguments: ConvertibleFromGeneratedContent>(
        _ tool: any Tool, arguments: Arguments.Type
    ) throws -> FailureDeliveringTextTool<Arguments> {
        try #require(ToolFailureDelivery.makeWrapped(tool: tool) as? FailureDeliveringTextTool<Arguments>)
    }

    // MARK: - Envelope and settlement helpers

    /// The decoded fields of an envelope.
    struct DecodedEnvelope: Decodable {
        /// The JSON keys of the envelope.
        private enum CodingKeys: String, CodingKey {
            case isPending = "pending"
            case completionToken
            case next
        }

        /// `true` while the run continues.
        let isPending: Bool

        /// The completion token of the run.
        let completionToken: String

        /// What the model must do next.
        let next: String
    }

    /// The error of a fixture helper, and of ``ThrowingTool``.
    struct FixtureError: Error, Equatable {}

    /// Decodes the envelope in `rendered`.
    static func decodeEnvelope(_ rendered: String) throws -> DecodedEnvelope {
        try JSONDecoder().decode(DecodedEnvelope.self, from: Data(rendered.utf8))
    }

    /// Waits for the run of `completionToken` to settle, and returns its
    /// terminal event. The wait sets no deadline, thus it reads no clock and
    /// ends only at the settlement.
    static func settledTerminal(of completionToken: String, in runPlane: RunPlane) async throws -> OperationEvent {
        let result = await runPlane.wait(completionToken: completionToken, seconds: nil)
        return try #require(result.settledTerminal, "run \(completionToken) did not settle: \(result)")
    }

    /// Waits until `sink` gets the elicitation event of a question, or until
    /// `ended` ends first, and returns the id of the question.
    ///
    /// - Parameters:
    ///   - sink: The sink that the question posts to.
    ///   - ended: The wait for the event that shows that no question comes,
    ///     for example the end of the call or the settle of the run.
    /// - Returns: The id of the first question that the sink got.
    /// - Throws: When the sink got no question.
    static func firstQuestionId(
        postedTo sink: RecordingSink, orUntil ended: @escaping @Sendable () async -> Void
    ) async throws -> ULID {
        await Waits.untilFirstEnds({ await sink.waitForAnEvent { $0.elicitation != nil } }, ended)
        let question = await sink.events.compactMap(\.elicitation).first
        return try #require(question?.elicitationId, "the sink got no question")
    }

    /// Waits until `sink` gets the elicitation event of a question, or until
    /// the run of `completionToken` settles first, and returns the id of the
    /// question.
    ///
    /// - Parameters:
    ///   - sink: The sink that the question posts to.
    ///   - completionToken: The completion token of the run that asks.
    ///   - runPlane: The run plane that tracks the run.
    /// - Returns: The id of the first question that the sink got.
    /// - Throws: When the sink got no question.
    static func firstQuestionId(
        postedTo sink: RecordingSink, byRun completionToken: String, on runPlane: RunPlane
    ) async throws -> ULID {
        try await firstQuestionId(postedTo: sink) {
            _ = await runPlane.wait(completionToken: completionToken, seconds: nil)
        }
    }

    // MARK: - Tools

    /// Returns at once.
    struct FastTool: Tool {
        let name = "fast_tool"
        let description = "returns immediately"

        func call(arguments: MountArguments) async throws -> String {
            "fast: \(arguments.value)"
        }
    }

    /// Returns at once, and tells if the run plane already tracked its run
    /// when its body started.
    struct TrackedAtStartTool: Tool {
        /// The output when the run was tracked before the body ran.
        static let trackedOutput = "tracked at start"

        let name = "tracked_at_start_tool"
        let description = "reports whether its run was tracked when it started"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let tracked = await context.runPlane.backgroundRuns().map(\.completionToken)
            return tracked.contains(context.completionToken) ? Self.trackedOutput : "untracked at start"
        }
    }

    /// Waits on its gate until the test opens it.
    struct GatedTool: Tool {
        let name = "gated_tool"
        let description = "blocks until its gate opens"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "gated: \(arguments.value)"
        }
    }

    /// Waits on its gate, declares ``RunKind/process``, and gives
    /// `processCanceler` as the canceler of each run. The canceler does not
    /// open the gate: the test opens it.
    struct GatedProcessTool: Tool, BackgroundTool {
        let name = "gated_process_tool"
        let description = "blocks until its gate opens, as a process run with its own canceler"
        let gate: RunLatch

        /// The canceler of each run of this tool.
        let processCanceler: @Sendable () async -> OperationOutcome

        /// Opens when the body starts, before it waits on its gate.
        var started = RunLatch()

        func call(arguments: MountArguments) async throws -> String {
            started.open()
            await gate.waitUntilOpen()
            return "process: \(arguments.value)"
        }

        var runKind: RunKind { .process }

        func canceler(forCompletionToken _: String) -> (@Sendable () async -> OperationOutcome)? {
            processCanceler
        }
    }

    /// Throws ``FixtureError`` at once.
    struct ThrowingTool: Tool {
        let name = "throwing_tool"
        let description = "throws immediately"

        func call(arguments: MountArguments) async throws -> String {
            throw FixtureError()
        }
    }

    /// Waits until its task is cancelled, then throws `CancellationError`.
    struct SleepingTool: Tool {
        let name = "sleeping_tool"
        let description = "sleeps until cancelled"

        func call(arguments: MountArguments) async throws -> String {
            try await Waits.untilCancelled()
            return "never returned"
        }
    }

    /// Posts one progress event, then returns.
    struct ProgressOnceTool: Tool {
        let name = "progress_once_tool"
        let description = "posts one progress event then returns"

        func call(arguments: MountArguments) async throws -> String {
            await ToolContext.current?.progress("halfway")
            return "progressed: \(arguments.value)"
        }
    }

    /// Posts one display event with the value of the call as a text chunk,
    /// then returns.
    struct DisplayOnceTool: Tool {
        let name = "display_once_tool"
        let description = "posts one display event then returns"

        func call(arguments: MountArguments) async throws -> String {
            await ToolContext.current?.post(display: .contentChunk(.text(arguments.value)))
            return "displayed: \(arguments.value)"
        }
    }

    /// Posts its own terminal event, then returns.
    struct OwnTerminalTool: Tool {
        let name = "own_terminal_tool"
        let description = "posts its own terminal event then returns"

        func call(arguments: MountArguments) async throws -> String {
            await ToolContext.current?.post(OperationEvent.terminal(outcome: .succeeded, detail: "my own terminal"))
            return "own-terminal: \(arguments.value)"
        }
    }

    /// Waits on its gate, posts `beats` progress events, opens `beaten`, then
    /// waits on `finish` and returns.
    struct HeartbeatTool: Tool {
        let name = "heartbeat_tool"
        let description = "posts periodic progress then returns"
        let beats: Int

        /// The gate that the first beat waits for.
        let gate: RunLatch

        /// Opens when the post of the last beat returned.
        let beaten: RunLatch

        /// The gate that the return waits for.
        let finish: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            for beat in 0..<beats {
                await ToolContext.current?.progress("beat \(beat)")
            }
            beaten.open()
            await finish.waitUntilOpen()
            return "heartbeat done"
        }
    }

    /// Waits until its task is cancelled, and declares a timeout for each
    /// call.
    struct PerCallTimeoutTool: Tool, BackgroundTool {
        let name = "per_call_timeout_tool"
        let description = "supplies a short per-call timeout"
        let timeoutSeconds: TimeInterval

        func call(arguments: MountArguments) async throws -> String {
            try await Waits.untilCancelled()
            return "never returned"
        }

        func timeout(from _: GeneratedContent) -> TimeInterval? {
            timeoutSeconds
        }
    }

    /// Waits until its task is cancelled, and declares no timeout for a
    /// call.
    struct NilTimeoutTool: Tool, BackgroundTool {
        let name = "nil_timeout_tool"
        let description = "supplies no per-call timeout at all"

        func call(arguments: MountArguments) async throws -> String {
            try await Waits.untilCancelled()
            return "never returned"
        }

        func timeout(from _: GeneratedContent) -> TimeInterval? {
            nil
        }
    }

    /// Waits on its gate, and gives its own collect sentence.
    struct CollectSentenceTool: Tool, BackgroundTool {
        let name = "collect_sentence_tool"
        let description = "names its own collect step"
        let gate: RunLatch

        /// The sentence of this tool for `completionToken`.
        static func collectInstruction(forCompletionToken completionToken: String) -> String {
            "Call the fetch tool with ticket \"\(completionToken)\" to read the result."
        }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "collected: \(arguments.value)"
        }

        func collectInstruction(forCompletionToken completionToken: String, describing _: String) -> String {
            Self.collectInstruction(forCompletionToken: completionToken)
        }
    }

    /// Waits on its gate, and describes each call from its arguments.
    struct DescribedCallTool: Tool, BackgroundTool {
        let name = "described_call_tool"
        let description = "describes each call by its arguments"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "described: \(arguments.value)"
        }

        func callDescription(for arguments: GeneratedContent) -> String? {
            guard let value = try? arguments.value(String.self, forProperty: "value") else { return nil }
            return "execute python \(value)"
        }
    }

    /// Waits on its gate, and states its own grace. A run that settles in the
    /// grace answers with the output of the tool.
    struct InlineGraceTool: Tool, BackgroundTool {
        let name = "inline_grace_tool"
        let description = "waits a short time for its own run before it answers"
        let gate: RunLatch
        let grace: TimeInterval

        /// The output of this tool for `value`.
        static func output(for value: String) -> String {
            "inline: \(value)"
        }

        var inlineSettleGrace: TimeInterval { grace }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return Self.output(for: arguments.value)
        }
    }

    /// A background tool that states no grace, so it uses the settle period
    /// of its site. It waits on its gate, then returns.
    struct SiteGraceTool: Tool, BackgroundTool {
        let name = "site_grace_tool"
        let description = "states no grace and uses the settle period of its site"
        let gate: RunLatch

        /// The output of this tool for `value`.
        static func output(for value: String) -> String {
            "site grace: \(value)"
        }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return Self.output(for: arguments.value)
        }
    }

    /// Waits on its gate, then throws ``FixtureError``. It states its own
    /// grace.
    struct InlineThrowingTool: Tool, BackgroundTool {
        let name = "inline_throwing_tool"
        let description = "throws after its gate opens"
        let gate: RunLatch
        let grace: TimeInterval

        var inlineSettleGrace: TimeInterval { grace }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            throw FixtureError()
        }
    }

    /// Cancels its own run on the run plane through its context, then ends
    /// at that cancel with `CancellationError`. The cancel stops only the
    /// run: the task of the call that waits for the run is not cancelled.
    struct SelfCancellingTool: Tool {
        let name = "self_cancelling_tool"
        let description = "cancels its own run, then ends at the cancel"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            _ = await context.cancel(completionToken: context.completionToken)
            try Task.checkCancellation()
            return "not cancelled: \(arguments.value)"
        }
    }

    /// A form question with one string field, `name`.
    ///
    /// - Parameter elicitationId: The id of the question. The default is a
    ///   new id.
    /// - Returns: The question.
    static func nameRequest(elicitationId: ULID = ULID()) -> ElicitationRequest {
        ElicitationRequest(
            message: "What is your name?",
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(properties: ["name": .string(ElicitationStringSchema())])
        )
    }

    /// A URL question with a new id.
    ///
    /// - Returns: The question.
    /// - Throws: When the URL does not parse.
    static func urlRequest() throws -> ElicitationRequest {
        ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: try #require(URL(string: "https://example.com/sign-in")))
    }

    /// Asks `request` through `context`, and appends the answer to `answers`.
    /// A question that throws records an issue.
    ///
    /// - Parameters:
    ///   - request: The question.
    ///   - context: The context of the run.
    ///   - answers: Gets the answer.
    static func recordAnswer(
        to request: ElicitationRequest, through context: ToolContext, in answers: Recorder<ElicitationResponse>
    ) async {
        do {
            answers.append(try await context.elicit(request))
        } catch {
            Issue.record(error, "the question threw")
        }
    }

    /// The question that the elicitation fixtures ask.
    static func proceedRequest() -> ElicitationRequest {
        ElicitationRequest(
            message: "Proceed?",
            elicitationId: ULID(),
            requestedSchema: ElicitationRequestedSchema(properties: ["ok": .boolean(ElicitationBooleanSchema())])
        )
    }

    /// Asks one question, then returns the action of the answer.
    struct ElicitOnceTool: Tool {
        let name = "elicit_once_tool"
        let description = "asks one question then returns"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let response = try await context.elicit(proceedRequest())
            return "answered: \(response.action.rawValue)"
        }
    }

    /// Calls the mounted tool of a background run in a synchronous mount, and
    /// returns its output. The inner tool is ``ElicitOnceTool``, thus it asks
    /// one question.
    struct MountingElicitTool: Tool {
        let name = "mounting_elicit_tool"
        let description = "mounts a tool that asks one question, and calls it"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            let inner = context.mount(ElicitOnceTool())
            return try await inner.call(arguments: arguments)
        }
    }

    /// Asks one question, then waits until its task is cancelled.
    struct ElicitThenStallTool: Tool {
        let name = "elicit_then_stall_tool"
        let description = "asks one question then stalls forever"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            _ = try await context.elicit(proceedRequest())
            try await Waits.untilCancelled()
            return "never returned"
        }
    }

    /// Keeps the context of the run of a ``CancellationFlagTool``, so a test
    /// reads the cancellation flag that the tool reads.
    struct CancellationWitness {
        /// Gets the context of the run when the tool starts.
        let context = Promise<ToolContext>()
    }

    /// Gives its context to its witness, waits until its task is cancelled,
    /// and then reads ``ToolContext/isCancelled``. It returns normally with
    /// what the flag tells.
    struct CancellationFlagTool: Tool {
        /// The output when the flag was set at the cancel.
        static let observedOutput = "observed cancellation"

        let name = "flag_reading_tool"
        let description = "returns when the ambient cancellation flag flips"
        let witness: CancellationWitness

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            witness.context.fulfill(context)
            // The tool ignores the cancellation error on purpose: it
            // cooperates through the flag only.
            try? await Waits.untilCancelled()
            return context.isCancelled ? Self.observedOutput : "never cancelled"
        }
    }

    // MARK: - Attachments

    /// The first record that the attaching fixtures attach.
    static let firstAttachment = ToolCallAttachment(
        schemaName: "FileChangeSet",
        contentJSON: #"{"changes":[{"path":"Sources/App.swift","kind":"modified"}]}"#
    )

    /// The second record that the attaching fixtures attach.
    static let secondAttachment = ToolCallAttachment(schemaName: "CommandExit", contentJSON: #"{"status":0}"#)

    /// The records of each attaching fixture, in call order.
    static let attachmentsInCallOrder = [firstAttachment, secondAttachment]

    /// Tells if `text` holds a part of an attached record.
    static func isAttachmentMentioned(in text: String) -> Bool {
        attachmentsInCallOrder.contains { attachment in
            text.contains(attachment.schemaName) || text.contains(attachment.contentJSON)
        }
    }

    /// Attaches both records, then returns.
    struct AttachingTool: Tool {
        let name = "attaching_tool"
        let description = "attaches two records then returns"

        func call(arguments: MountArguments) async throws -> String {
            attachInCallOrder()
            return "attached: \(arguments.value)"
        }
    }

    /// Attaches the first record, waits on its gate, attaches the second
    /// record, then returns.
    struct GatedAttachingTool: Tool {
        let name = "gated_attaching_tool"
        let description = "attaches one record, waits for its gate, then attaches a second"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            ToolContext.current?.attach(firstAttachment)
            await gate.waitUntilOpen()
            ToolContext.current?.attach(secondAttachment)
            return "attached late: \(arguments.value)"
        }
    }
}
