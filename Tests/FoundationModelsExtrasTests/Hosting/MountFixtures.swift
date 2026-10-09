@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
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

    /// The limit of each wait that a test does on the run plane.
    static let settlementDeadline: TimeInterval = 30

    /// One hour in nanoseconds: the sleep of a tool that must never return.
    static let hourInNanoseconds: UInt64 = 3_600_000_000_000

    /// The pause between two polls, in nanoseconds.
    static let pollIntervalNanoseconds: UInt64 = 5_000_000

    /// The number of polls before a bounded poll stops.
    static let pollAttempts = 1_000

    // MARK: - Sink

    /// A sink that keeps each event, each display event and each report, in
    /// order.
    actor RecordingSink: OperationEventSink, ToolCallReportSink {
        /// Each event, in post order.
        private(set) var events: [OperationEvent] = []

        /// Each display event, in post order.
        private(set) var displays: [ToolDisplayEvent] = []

        /// Each report, in post order.
        private(set) var reports: [ToolCallReport] = []

        /// Keeps `event`.
        func post(event: OperationEvent) {
            events.append(event)
        }

        /// Keeps `event`.
        func post(display event: ToolDisplayEvent) {
            displays.append(event)
        }

        /// Keeps `report`.
        func post(report: ToolCallReport) {
            reports.append(report)
        }
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
    /// - Returns: The mount site.
    static func site(
        runPlane: RunPlane,
        sink: any OperationEventSink,
        inlineSettleGrace: TimeInterval = pendingAtOnceGrace
    ) -> MountSite {
        MountSite(sessionID: ULID(), runPlane: runPlane, sink: sink, inlineSettleGrace: inlineSettleGrace)
    }

    /// Mounts `tool` in a ``BackgroundToolRunner`` over a new run plane and
    /// sink.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - timeout: The timeout of the mount, or `nil` for none.
    ///   - inlineSettleGrace: The settle period of the site. The default is
    ///     ``pendingAtOnceGrace``.
    static func backgroundHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = nil,
        inlineSettleGrace: TimeInterval = pendingAtOnceGrace
    ) -> Harness<BackgroundToolRunner<Arguments>> {
        let runPlane = RunPlane()
        let sink = RecordingSink()
        let site = site(runPlane: runPlane, sink: sink, inlineSettleGrace: inlineSettleGrace)
        let mounted = BackgroundToolRunner(wrapping: tool, site: site, timeout: timeout)
        return Harness(runPlane: runPlane, sink: sink, mounted: mounted)
    }

    /// Mounts `tool` in a ``RunToCompletionRunner`` over a new run plane and
    /// sink.
    static func runToCompletionHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = nil
    ) -> Harness<RunToCompletionRunner<Arguments>> {
        let runPlane = RunPlane()
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
        ToolRun(
            wrapped: tool, arguments: arguments, site: site(runPlane: RunPlane(), sink: sink), mountTimeout: nil,
            inlineSettleDeadline: nil)
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
    /// terminal event.
    static func settledTerminal(of completionToken: String, in runPlane: RunPlane) async throws -> OperationEvent {
        let result = await runPlane.wait(completionToken: completionToken, seconds: settlementDeadline)
        return try #require(result.settledTerminal, "run \(completionToken) did not settle: \(result)")
    }

    /// Waits, with no wall clock, until an elicitation is pending on
    /// `runPlane`, and returns its id. The caller sets a `.timeLimit`.
    static func firstPendingElicitationId(in runPlane: RunPlane) async throws -> ULID {
        try await AwaitedCondition.wait { await !runPlane.pendingElicitationIds().isEmpty }
        return try #require(await runPlane.pendingElicitationIds().first)
    }

    /// Polls `fact`, with a bound, until it gives a value.
    static func poll<Value>(_ fact: () async -> Value?) async throws -> Value? {
        for _ in 0..<pollAttempts {
            if let value = await fact() {
                return value
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return nil
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

        func call(arguments: MountArguments) async throws -> String {
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

    /// Sleeps until it is cancelled.
    struct SleepingTool: Tool {
        let name = "sleeping_tool"
        let description = "sleeps until cancelled"

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(nanoseconds: hourInNanoseconds)
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
            await ToolContext.current?.post(
                OperationEvent(
                    tool: "", op: "", correlationID: "", kind: .completed,
                    detail: "my own terminal", outcome: .succeeded
                )
            )
            return "own-terminal: \(arguments.value)"
        }
    }

    /// Posts progress each `interval` seconds for `beats` beats, then returns.
    struct HeartbeatTool: Tool {
        let name = "heartbeat_tool"
        let description = "posts periodic progress then returns"
        let beats: Int
        let interval: TimeInterval

        func call(arguments: MountArguments) async throws -> String {
            for beat in 0..<beats {
                try await Task.sleep(for: .seconds(interval))
                await ToolContext.current?.progress("beat \(beat)")
            }
            return "heartbeat done"
        }
    }

    /// Sleeps for an hour, and declares a timeout for each call.
    struct PerCallTimeoutTool: Tool, BackgroundTool {
        let name = "per_call_timeout_tool"
        let description = "supplies a short per-call timeout"
        let timeoutSeconds: TimeInterval

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(nanoseconds: hourInNanoseconds)
            return "never returned"
        }

        func timeout(from _: GeneratedContent) -> TimeInterval? {
            timeoutSeconds
        }
    }

    /// Sleeps for an hour, and declares no timeout for a call.
    struct NilTimeoutTool: Tool, BackgroundTool {
        let name = "nil_timeout_tool"
        let description = "supplies no per-call timeout at all"

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(nanoseconds: hourInNanoseconds)
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

        func collectInstruction(forCompletionToken completionToken: String) -> String {
            Self.collectInstruction(forCompletionToken: completionToken)
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

    /// Asks one question, then sleeps for an hour.
    struct ElicitThenStallTool: Tool {
        let name = "elicit_then_stall_tool"
        let description = "asks one question then stalls forever"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            _ = try await context.elicit(proceedRequest())
            try await Task.sleep(nanoseconds: hourInNanoseconds)
            return "never returned"
        }
    }

    /// Records that a tool saw the cancellation flag of its run.
    actor CancellationWitness {
        /// Whether the tool saw the flag.
        private(set) var isObserved = false

        /// Records that the tool saw the flag.
        func mark() {
            isObserved = true
        }
    }

    /// Polls ``ToolContext/isCancelled``, never the task cancellation, and
    /// returns when the flag is set.
    struct CancellationFlagPollingTool: Tool {
        let name = "flag_polling_tool"
        let description = "returns when the ambient cancellation flag flips"
        let witness: CancellationWitness

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            for _ in 0..<pollAttempts {
                if context.isCancelled {
                    await witness.mark()
                    return "observed cancellation"
                }
                // The tool ignores the cancellation error on purpose: it
                // cooperates through the flag only.
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
            return "never cancelled"
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
