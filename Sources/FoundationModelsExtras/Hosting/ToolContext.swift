import Foundation
import FoundationModels
import ULID

/// What a running tool can use: the run plane, the event sink and the session
/// of its call, and the `tool`, `op` and `completionToken` of its run.
///
/// A runner binds the context around each call with
/// `ToolContext.$current.withValue(context)`. A task that does not inherit the
/// task-local values does not see it, so read the context one time, when the
/// operation starts.
struct ToolContext: Sendable {
    /// The context of the current task, or `nil` outside a tool call.
    @TaskLocal static var current: ToolContext?

    /// The session of the call.
    let sessionID: ULID

    /// The run plane of the session.
    let runPlane: RunPlane

    /// The sink that each capability posts to.
    private let sink: any OperationEventSink

    /// Tells if a cancel of the run was asked.
    private let cancellationProbe: @Sendable () -> Bool

    /// Gets each record that the tool attaches.
    private let attachmentSink: @Sendable (ToolCallAttachment) -> Void

    /// The tool name on each event of the run. Never empty.
    let tool: String

    /// The `"verb noun"` op on each event of the run. Never empty.
    let op: String

    /// The completion token of the run. It is the `correlationID` of each
    /// event of the run.
    let completionToken: String

    /// Makes a context.
    ///
    /// - Parameters:
    ///   - sessionID: The session of the call.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink that each capability posts to.
    ///   - tool: The tool name of the run. Must not be empty.
    ///   - op: The op of the run. Must not be empty.
    ///   - completionToken: The completion token of the run.
    ///   - isCancelled: Tells if a cancel of the run was asked.
    ///   - attachmentSink: Gets each attached record. The default drops it.
    init(
        sessionID: ULID,
        runPlane: RunPlane,
        sink: any OperationEventSink,
        tool: String,
        op: String,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool,
        attachmentSink: @escaping @Sendable (ToolCallAttachment) -> Void = { _ in }
    ) {
        precondition(!tool.isEmpty, "the tool name of a ToolContext must not be empty")
        precondition(!op.isEmpty, "the op of a ToolContext must not be empty")
        self.sessionID = sessionID
        self.runPlane = runPlane
        self.sink = sink
        self.tool = tool
        self.op = op
        self.completionToken = completionToken
        self.cancellationProbe = isCancelled
        self.attachmentSink = attachmentSink
    }

    /// Makes the context of one call of `tool` on `site`, with the name of
    /// the tool, or its type name when the name is empty. The op is the op of
    /// the site, or the tool name when the site has none.
    ///
    /// - Parameters:
    ///   - tool: The called tool.
    ///   - site: The mount site of the call.
    ///   - sink: The sink that each capability posts to.
    ///   - completionToken: The completion token of the run.
    ///   - state: The cancel flag and the records of the call.
    init(calling tool: any Tool, on site: MountSite, sink: any OperationEventSink, completionToken: String, state: ToolCallState) {
        let name = tool.name.isEmpty ? String(describing: type(of: tool)) : tool.name
        self.init(
            sessionID: site.sessionID,
            runPlane: site.runPlane,
            sink: sink,
            tool: name,
            op: site.op.flatMap { $0.isEmpty ? nil : $0 } ?? name,
            completionToken: completionToken,
            isCancelled: { state.isCancelRequested },
            attachmentSink: { state.attach($0) }
        )
    }

    /// Whether a cancel of the run was asked.
    var isCancelled: Bool {
        cancellationProbe()
    }

    // MARK: - Events

    /// Posts `event` with the `tool`, `op` and `completionToken` of this run.
    /// Only the kind, the detail, the outcome and the elicitation of `event`
    /// stay.
    ///
    /// - Parameter event: The event to post.
    func post(_ event: OperationEvent) async {
        await sink.post(event: stamped(event.kind, detail: event.detail, outcome: event.outcome, elicitation: event.elicitation))
    }

    /// Posts a `.progress` event with `detail`, stamped as ``post(_:)`` does.
    ///
    /// - Parameter detail: The progress detail.
    func progress(_ detail: String) async {
        await sink.post(event: stamped(.progress, detail: detail))
    }

    /// Attaches `attachment` to the call of this context.
    ///
    /// The records go on the ``ToolCallReport`` of the call, in call order,
    /// after the close record. The model never reads them, and they never
    /// become events. A record attached after the call closed is dropped.
    ///
    /// - Parameter attachment: The record.
    func attach(_ attachment: ToolCallAttachment) {
        attachmentSink(attachment)
    }

    /// Asks the user a question while the run continues.
    ///
    /// The run waits on the run plane under the `elicitationId` of the
    /// request, and the request goes to the sink as an elicitation event.
    /// Only an answer, a completion, or the sweep of the run plane resumes the
    /// run. A cancel of the task does not. This function never throws now.
    ///
    /// - Parameter request: The question.
    /// - Returns: The answer of the user.
    func elicit(_ request: ElicitationRequest) async throws -> ElicitationResponse {
        let event = stamped(.elicitation, detail: "", elicitation: request)
        let sink = sink
        return await runPlane.awaitAnswer(to: request) {
            await sink.post(event: event)
        }
    }

    // MARK: - The run plane

    /// Each open background run of the session, in start order.
    ///
    /// - Returns: The runs, with no output.
    func backgroundRuns() async -> [BackgroundRun] {
        await runPlane.backgroundRuns()
    }

    /// Waits until a background run settles. See
    /// ``RunPlane/wait(completionToken:seconds:)``.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - seconds: The deadline, or `nil` for none.
    /// - Returns: The ``WaitOutcome``.
    func wait(completionToken: String, seconds: Double?) async -> WaitOutcome {
        await runPlane.wait(completionToken: completionToken, seconds: seconds)
    }

    /// Asks a background run to stop. See
    /// ``RunPlane/cancel(completionToken:)``.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The ``CancelOutcome``.
    func cancel(completionToken: String) async -> CancelOutcome {
        await runPlane.cancel(completionToken: completionToken)
    }

    // MARK: - Mounting

    // Tool hosting 4 (^ebtprdg) makes the mount API public and copies its tests.
    // periphery:ignore
    /// Mounts `tool` on the session of this run, for a caller that makes its
    /// own inner tool calls, for example a script runner.
    ///
    /// The mounted tool works as a tool of the session: each call gets its own
    /// context and span, and a background mount tracks its run on the run
    /// plane. Each event of a mounted run goes through ``post(_:)``, so it has
    /// the correlation of THIS run. Each record that a mounted call attaches
    /// goes on THIS run. The own token of a mounted run stays on the run
    /// plane.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - op: The op of the mounted runs, or `nil` for the tool name.
    ///   - configuration: The mount when `tool` declares none.
    /// - Returns: The mounted tool, with the `Arguments` and `Output` of `tool`.
    func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous
    ) -> any Tool<T.Arguments, T.Output> {
        mount(tool, op: op, as: configuration, postingTo: MountedRunUpstreamSink(context: self))
    }

    // Tool hosting 4 (^ebtprdg) makes the mount API public and copies its tests.
    // periphery:ignore
    /// Mounts `tool` as ``mount(_:op:as:)`` does, but each mounted run posts
    /// its events to `sink` with its own completion token. Use it to tell two
    /// runs of one tool apart. The report of a mounted call does not reach a
    /// `sink` that is not a ``ToolCallReportSink``.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - op: The op of the mounted runs, or `nil` for the tool name.
    ///   - configuration: The mount when `tool` declares none.
    ///   - sink: The sink of each mounted run.
    /// - Returns: The mounted tool, with the `Arguments` and `Output` of `tool`.
    func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous,
        postingTo sink: any OperationEventSink
    ) -> any Tool<T.Arguments, T.Output> {
        let site = MountSite(sessionID: sessionID, runPlane: runPlane, sink: sink, op: op)
        let mounted = ToolMounting.makeWrapped(tool: tool, site: site, configuration: configuration)
        // Each mount keeps `Arguments` and `Output`, so the cast does not
        // fail. The fallback calls the tool with no mount.
        return mounted as? any Tool<T.Arguments, T.Output> ?? tool
    }

    // Tool hosting 4 (^ebtprdg) makes this public and copies its tests.
    // periphery:ignore
    /// A new completion token. In a tool call, use ``completionToken`` of
    /// ``current``: a new token names no tracked run.
    ///
    /// - Returns: A ULID string.
    static func makeCompletionToken() -> String {
        RunPlane.makeCompletionToken()
    }

    /// An event of `kind` with the stamps of this run.
    private func stamped(
        _ kind: OperationEventKind,
        detail: String,
        outcome: OperationOutcome? = nil,
        elicitation: ElicitationRequest? = nil
    ) -> OperationEvent {
        OperationEvent(
            tool: tool, op: op, correlationID: completionToken, kind: kind,
            detail: detail, outcome: outcome, elicitation: elicitation
        )
    }
}

extension ToolInvocationRecord {
    /// The open record of the call of `context`, opened now.
    ///
    /// - Parameter context: The context of the call.
    init(opening context: ToolContext) {
        self.init(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            sessionID: context.sessionID,
            openedAt: Date()
        )
    }
}

// Tool hosting 4 (^ebtprdg) copies the tests of the mount API.
// periphery:ignore
/// The sink of a run that ``ToolContext/mount(_:op:as:)`` mounted. It posts
/// each event through the mounting context, so the event gets the correlation
/// of the mounting run. It also gives each record of a mounted call to the
/// mounting context, so the records go on the report of the mounting run.
private struct MountedRunUpstreamSink: OperationEventSink, ToolCallReportSink {
    /// The mounting context.
    let context: ToolContext

    /// Posts `event` through the mounting context.
    ///
    /// - Parameter event: The event of the mounted run.
    func post(event: OperationEvent) async {
        await context.post(event)
    }

    /// Attaches each record of `report` to the mounting context, in order.
    ///
    /// - Parameter report: The report of the mounted call.
    func post(report: ToolCallReport) async {
        for attachment in report.attachments {
            context.attach(attachment)
        }
    }
}
