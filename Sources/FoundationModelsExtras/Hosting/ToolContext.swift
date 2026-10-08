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
public struct ToolContext: Sendable {
    /// The context of the current task, or `nil` outside a tool call.
    @TaskLocal public static var current: ToolContext?

    /// The session of the call.
    public let sessionID: ULID

    /// The run plane of the session.
    let runPlane: RunPlane

    /// The sink that each capability posts to.
    private let sink: any OperationEventSink

    /// The sink of the session. Each background run that this context mounts
    /// posts to it.
    private let sessionSink: any OperationEventSink

    /// Tells if a cancel of the run was asked.
    private let cancellationProbe: @Sendable () -> Bool

    /// Gets each record that the tool attaches.
    private let attachmentSink: @Sendable (ToolCallAttachment) -> Void

    /// The tool name on each event of the run. Never empty.
    public let tool: String

    /// The `"verb noun"` op on each event of the run. Never empty.
    public let op: String

    /// The completion token of the run. It is the `correlationID` of each
    /// event of the run.
    public let completionToken: String

    /// Makes a context. A host makes one to bind around work that it runs
    /// for a session, for example a model call.
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
    public init(
        sessionID: ULID,
        runPlane: RunPlane,
        sink: any OperationEventSink,
        tool: String,
        op: String,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool,
        attachmentSink: @escaping @Sendable (ToolCallAttachment) -> Void = { _ in }
    ) {
        self.init(
            site: MountSite(sessionID: sessionID, runPlane: runPlane, sink: sink),
            sink: sink,
            tool: tool,
            op: op,
            completionToken: completionToken,
            isCancelled: isCancelled,
            attachmentSink: attachmentSink
        )
    }

    /// Makes a context on `site`. It posts to `sink`, and each background run
    /// that it mounts posts to the sink of the session of `site`.
    ///
    /// - Parameters:
    ///   - site: The session, its run plane and its sink.
    ///   - sink: The sink that each capability posts to.
    ///   - tool: The tool name of the run. Must not be empty.
    ///   - op: The op of the run. Must not be empty.
    ///   - completionToken: The completion token of the run.
    ///   - isCancelled: Tells if a cancel of the run was asked.
    ///   - attachmentSink: Gets each attached record.
    private init(
        site: MountSite,
        sink: any OperationEventSink,
        tool: String,
        op: String,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool,
        attachmentSink: @escaping @Sendable (ToolCallAttachment) -> Void
    ) {
        precondition(!tool.isEmpty, "the tool name of a ToolContext must not be empty")
        precondition(!op.isEmpty, "the op of a ToolContext must not be empty")
        self.sessionID = site.sessionID
        self.runPlane = site.runPlane
        self.sink = sink
        self.sessionSink = site.sessionSink
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
            site: site,
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
    /// Only the kind, the detail, the outcome, the elicitation and the plan of
    /// `event` stay.
    ///
    /// - Parameter event: The event to post.
    public func post(_ event: OperationEvent) async {
        await sink.post(
            event: stamped(
                event.kind, detail: event.detail, outcome: event.outcome,
                elicitation: event.elicitation, plan: event.plan
            )
        )
    }

    /// Posts a `.progress` event with `detail` and `plan`, stamped as
    /// ``post(_:)`` does.
    ///
    /// The model gets only `detail`. The plan goes to the host, and the model
    /// never gets it.
    ///
    /// - Parameters:
    ///   - detail: A short text line for the model, for example
    ///     "3 of 7 tasks done".
    ///   - plan: The full agent plan for the host, or `nil` for none.
    public func progress(_ detail: String, plan: PlanSnapshot? = nil) async {
        await sink.post(event: stamped(.progress, detail: detail, plan: plan))
    }

    /// Sends `text` as mail to the session that called this run, while the
    /// run continues. Posts a `.message` event with `text` as its detail,
    /// stamped as ``post(_:)`` does. A message counts as a sign of life for
    /// the timeout of the run, the same as progress. A message after the
    /// terminal event of the run is dropped, because no call waits for it.
    ///
    /// - Parameter text: The text of the message.
    public func message(_ text: String) async {
        await sink.post(event: stamped(.message, detail: text))
    }

    /// Attaches `attachment` to the call of this context.
    ///
    /// The records go on the ``ToolCallReport`` of the call, in call order,
    /// after the close record. The model never reads them, and they never
    /// become events. A record attached after the call closed is dropped.
    ///
    /// - Parameter attachment: The record.
    public func attach(_ attachment: ToolCallAttachment) {
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
    public func elicit(_ request: ElicitationRequest) async throws -> ElicitationResponse {
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
    public func backgroundRuns() async -> [BackgroundRun] {
        await runPlane.backgroundRuns()
    }

    /// Waits until a background run settles, with a deadline or with none.
    ///
    /// A settled run answers at once. An unknown token does nothing. A cancel
    /// of the calling task ends the wait with ``WaitOutcome/cancelled``.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - seconds: The deadline, or `nil` for none.
    /// - Returns: The ``WaitOutcome``.
    public func wait(completionToken: String, seconds: Double?) async -> WaitOutcome {
        await runPlane.wait(completionToken: completionToken, seconds: seconds)
    }

    /// Asks a background run to stop, and reports the outcome that its
    /// canceler gives. The run stays open until it settles.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The ``CancelOutcome``.
    public func cancel(completionToken: String) async -> CancelOutcome {
        await runPlane.cancel(completionToken: completionToken)
    }

    // MARK: - Mounting

    /// Mounts `tool` on the session of this run, for a caller that makes its
    /// own inner tool calls, for example a script runner.
    ///
    /// The mounted tool works as a tool of the session: each call gets its own
    /// context and span. Each event of a synchronous call goes through
    /// ``post(_:)``, so it has the correlation of THIS run. The terminal event
    /// of a synchronous call goes as a `.progress` event with the same
    /// detail, because only THIS run gives its own terminal event. Each record
    /// that a synchronous call attaches goes on THIS run.
    ///
    /// A background call is a full background run, the same as a top-level
    /// one: the run plane tracks it, and its events and its terminal go to
    /// the sink of the session under its own token.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - op: The op of the mounted runs, or `nil` for the tool name.
    ///   - configuration: The mount when `tool` declares none.
    /// - Returns: The mounted tool, with the `Arguments` and `Output` of `tool`.
    public func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous
    ) -> any Tool<T.Arguments, T.Output> {
        let site = MountSite(
            sessionID: sessionID,
            runPlane: runPlane,
            sink: MountedRunUpstreamSink(context: self),
            sessionSink: sessionSink,
            op: op,
            tracer: nil
        )
        return Self.mount(tool, on: site, as: configuration)
    }

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
    public func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous,
        postingTo sink: any OperationEventSink
    ) -> any Tool<T.Arguments, T.Output> {
        Self.mount(tool, on: MountSite(sessionID: sessionID, runPlane: runPlane, sink: sink, op: op), as: configuration)
    }

    /// Mounts `tool` on `site`, and keeps the types of `tool`.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - site: Where the tool runs.
    ///   - configuration: The mount when `tool` declares none.
    /// - Returns: The mounted tool, with the `Arguments` and `Output` of `tool`.
    private static func mount<T: Tool>(
        _ tool: T,
        on site: MountSite,
        as configuration: ToolMount
    ) -> any Tool<T.Arguments, T.Output> {
        let mounted = ToolMounting.makeWrapped(tool: tool, site: site, configuration: configuration)
        // Each mount keeps `Arguments` and `Output`, so the cast does not
        // fail. The fallback calls the tool with no mount.
        return mounted as? any Tool<T.Arguments, T.Output> ?? tool
    }

    /// A new completion token. In a tool call, use ``completionToken`` of
    /// ``current``: a new token names no tracked run.
    ///
    /// - Returns: A ULID string.
    public static func makeCompletionToken() -> String {
        RunPlane.makeCompletionToken()
    }

    /// An event of `kind` with the stamps of this run.
    private func stamped(
        _ kind: OperationEventKind,
        detail: String,
        outcome: OperationOutcome? = nil,
        elicitation: ElicitationRequest? = nil,
        plan: PlanSnapshot? = nil
    ) -> OperationEvent {
        OperationEvent(
            tool: tool, op: op, correlationID: completionToken, kind: kind,
            detail: detail, outcome: outcome, elicitation: elicitation, plan: plan
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

/// The sink of a synchronous call that ``ToolContext/mount(_:op:as:)``
/// mounted. It posts each event through the mounting context, so the event
/// gets the correlation of the mounting run. It also gives each record of a
/// mounted call to the mounting context, so the records go on the report of
/// the mounting run.
///
/// The terminal event of the mounted run is not a terminal event of the
/// mounting run. The mounting run can catch a failure of the mounted call and
/// go on, and only the mounting run settles itself. Thus this sink posts the
/// terminal event of the mounted run as progress of the mounting run.
private struct MountedRunUpstreamSink: OperationEventSink, ToolCallReportSink {
    /// The mounting context.
    let context: ToolContext

    /// Posts `event` through the mounting context. A `.completed` event goes
    /// as a `.progress` event with the same detail.
    ///
    /// - Parameter event: The event of the mounted run.
    func post(event: OperationEvent) async {
        guard event.kind == .completed else {
            await context.post(event)
            return
        }
        await context.progress(event.detail)
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
