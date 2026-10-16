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

    /// The site of this run: the session, its run plane, the sink of the
    /// session, the tracer, the settle period, and the run that holds each
    /// synchronous call. Each tool that this context mounts runs on a copy of
    /// it, so a new field of ``MountSite`` reaches each mount with no edit
    /// here.
    private var runSite: MountSite

    /// The sink that each capability posts to.
    private let sink: any OperationEventSink

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

    /// The completion token of the run that holds this call.
    ///
    /// A host reads it to know if two contexts belong to one run. Each inner
    /// call has its own ``completionToken``, thus that token cannot tell
    /// that two inner calls come from one run. This value can:
    ///
    /// - The context of a run gives its own ``completionToken``.
    /// - Each synchronous call that the run mounts with
    ///   ``mount(_:op:as:)`` gives the token of that run, also when a
    ///   synchronous call mounts a synchronous call of its own.
    /// - A background call is a run of its own, thus it gives its own
    ///   ``completionToken``.
    /// - A context that a host makes with the public init gives its own
    ///   ``completionToken``.
    ///
    /// Thus two runs give different values. Each question that this context
    /// asks links to this run, and ``OpenElicitation/runToken`` of the
    /// question gives the same value, because a question of a synchronous
    /// call stops the run that holds it.
    public var holdingRunToken: String {
        // The init puts a token on the site, so the fallback only gives the
        // type.
        runSite.holdingRunToken ?? completionToken
    }

    /// The session of the call.
    public var sessionID: ULID {
        runSite.sessionID
    }

    /// The run plane of the session.
    var runPlane: RunPlane {
        runSite.runPlane
    }

    /// Tells if a user can answer questions in the session of the call.
    ///
    /// The host sets the value one time, when it makes the run plane of the
    /// session, and each context of the session gives the same value. A tool
    /// can read it to show a question feature only when a user is present.
    /// In a ``UserPresence/headless`` session, ``elicit(_:)`` returns a cancel
    /// with ``RunPlane/noUserPresentReason`` at once.
    public var userPresence: UserPresence {
        runPlane.userPresence
    }

    /// The configured settle period of the session, in seconds. Each tool
    /// that this context mounts uses it. See ``MountSite``.
    public var inlineSettleGrace: TimeInterval {
        runSite.inlineSettleGrace
    }

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
    ///   - inlineSettleGrace: The settle period of each background call that
    ///     this context mounts, in seconds. The default is
    ///     ``ToolMount/defaultInlineSettleGrace``.
    public init(
        sessionID: ULID,
        runPlane: RunPlane,
        sink: any OperationEventSink,
        tool: String,
        op: String,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool,
        attachmentSink: @escaping @Sendable (ToolCallAttachment) -> Void = { _ in },
        inlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace
    ) {
        self.init(
            site: MountSite(sessionID: sessionID, runPlane: runPlane, sink: sink, inlineSettleGrace: inlineSettleGrace),
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
    /// The run that holds the call is the holding run of `site`. When `site`
    /// names none, the call is a run of its own, and `completionToken` holds
    /// it.
    ///
    /// - Parameters:
    ///   - site: The session, its run plane, its sink, its tracer, its settle
    ///     period, and the run that holds the call.
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
        self.runSite = site.held(
            by: site.holdingRunToken ?? completionToken, settlingBy: site.inlineSettleDeadline)
        self.sink = sink
        self.tool = tool
        self.op = op
        self.completionToken = completionToken
        self.cancellationProbe = isCancelled
        self.attachmentSink = attachmentSink
    }

    /// Makes the context of one call of `tool` on `site`, with the name of
    /// the tool, or its type name when the name is empty. The op is the op of
    /// the site, or the tool name when the site has none. The settle period
    /// and the run that holds the call come from `site`.
    ///
    /// - Parameters:
    ///   - tool: The called tool.
    ///   - site: The mount site of the call.
    ///   - sink: The sink that each capability posts to.
    ///   - completionToken: The completion token of the run.
    ///   - state: The cancel flag and the records of the call.
    init(
        calling tool: any Tool,
        on site: MountSite,
        sink: any OperationEventSink,
        completionToken: String,
        state: ToolCallState
    ) {
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

    /// Sends `kind` to the client as a ``ToolDisplayEvent``, stamped with the
    /// `tool`, `op` and `completionToken` of this run.
    ///
    /// The event goes to ``OperationEventSink/post(display:)`` of the sink.
    /// It never goes into the model input, it never changes the progress
    /// detail of the run, and a host never combines it with another event.
    /// It counts as a sign of life for the timeout of the run, the same as
    /// progress.
    ///
    /// - Parameter kind: The output or the metadata for the client.
    public func post(display kind: ToolDisplayEvent.Kind) async {
        await sink.post(
            display: ToolDisplayEvent(tool: tool, op: op, correlationID: completionToken, kind: kind))
    }

    /// Sends `chunk` to the client as one more part of the output of the
    /// call. Posts a ``ToolDisplayEvent/Kind/contentChunk(_:)`` display event
    /// through ``post(display:)``.
    ///
    /// - Parameter chunk: The part of the output that the client adds after
    ///   the earlier parts.
    public func emit(chunk: ToolDisplayContent) async {
        await post(display: .contentChunk(chunk))
    }

    /// Sends new metadata of the call to the client. Posts a
    /// ``ToolDisplayEvent/Kind/metadata(title:kind:locations:rawInput:)``
    /// display event through ``post(display:)``, with no raw input.
    ///
    /// A `nil` argument does not change the value that the client has.
    ///
    /// - Parameters:
    ///   - title: The human-readable title of the call, or `nil`.
    ///   - kind: The category of the call, or `nil`.
    ///   - locations: The files that the call reads or changes, or `nil`.
    public func update(
        title: String? = nil,
        kind: ToolDisplayEvent.ToolKind? = nil,
        locations: [ToolDisplayEvent.Location]? = nil
    ) async {
        await post(display: .metadata(title: title, kind: kind, locations: locations, rawInput: nil))
    }

    /// Tells the sink of this context that the accepted URL flow of
    /// `elicitationId` completed. A synchronous call that this context
    /// mounted sends the completion of its question through here, so the
    /// completion takes the same sink path as the question.
    ///
    /// - Parameter elicitationId: The id of the question.
    fileprivate func postElicitationCompleted(_ elicitationId: ULID) async {
        await sink.post(elicitationCompleted: elicitationId)
    }

    /// Tells the sink of this context that an end of the run plane ended
    /// the question of `elicitationId`. A synchronous call that this context
    /// mounted sends the end of its question through here, so the end takes
    /// the same sink path as the question.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - response: The answer that the run of the question gets.
    fileprivate func postElicitationEnded(_ elicitationId: ULID, response: ElicitationResponse) async {
        await sink.post(elicitationEnded: elicitationId, response: response)
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
    /// Only an answer, a completion, a cancel of the run that holds this
    /// call, or the sweep of the run plane resumes the run. A cancel of the
    /// task does not. A cancel of the run, the sweep and
    /// ``RunPlane/cancelOpenElicitations()`` give a cancel with
    /// ``RunPlane/runCancelledReason``.
    ///
    /// This function does not throw. Each result, also a cancel, a decline and
    /// an answer that is not valid, comes back as an ``ElicitationResponse``.
    /// The declaration keeps `throws` only so that a later check of a
    /// malformed request can throw with no change to the callers. Today no
    /// request throws.
    ///
    /// When an open question already has the `elicitationId` of the request,
    /// this function does not throw. It returns a cancel with the reason
    /// "an open elicitation already has this elicitationId" at once. The
    /// request does not go to the sink, and the open question does not
    /// change.
    ///
    /// A host can also end the question with
    /// ``RunPlane/endElicitation(_:with:)``. Then the run gets the decline or
    /// the cancel of that call. That call accepts only a decline or a cancel:
    /// an accept hits a precondition and stops the process, because only the
    /// user accepts a question.
    ///
    /// When the run plane ends the question (a cancel, or
    /// ``RunPlane/endElicitation(_:with:)``), the sink of this context gets
    /// ``OperationEventSink/post(elicitationEnded:response:)``, in order with
    /// the events of the run: after the elicitation event of the question,
    /// and before the run gets the answer of the end.
    ///
    /// The answer has the shape `{ action, content, reason }`. A decline and
    /// a cancel have no content, and they can carry a
    /// ``ElicitationResponse/reason`` that tells why the question ended with
    /// no answer. A cancel is not an error.
    ///
    /// While the question is open, it links to the run that holds this call,
    /// and ``RunPlane/runsWaitingOnlyForUser()`` lists that run.
    ///
    /// In a headless session (``RunPlane/userPresence`` is
    /// ``UserPresence/headless``), this function returns a cancel with
    /// ``RunPlane/noUserPresentReason`` at once. The request does not go to
    /// the sink, no question opens, and the run does not wait.
    ///
    /// After a cancel of the run that holds this call
    /// (``RunPlane/cancel(completionToken:)`` or ``RunPlane/sweep()``), this
    /// function returns a cancel with ``RunPlane/runCancelledReason`` at once,
    /// in the same way. Thus a run that asks again after a cancel does not
    /// wait. A sweep also cancels the token of each question that it ends.
    ///
    /// After the run that holds this call settled with no cancel, this
    /// function returns a cancel with ``RunPlane/runEndedReason`` at once, in
    /// the same way. For example, a child task that asks after the body of
    /// its run returned.
    ///
    /// The run gets no content that is not valid. When the request is in form
    /// mode and the answer is an accept, this function checks the content with
    /// ``ElicitationRequestedSchema/validationFailure(of:)``. When the check
    /// finds a failure, the run gets a decline with no content, and its
    /// reason is ``ElicitationRequestedSchema/invalidAnswerReasonPrefix``
    /// followed by the failure. Each other answer, and each accept of a URL
    /// question, reaches the run unchanged.
    ///
    /// - Parameter request: The question.
    /// - Returns: The answer of the user.
    public func elicit(_ request: ElicitationRequest) async throws -> ElicitationResponse {
        let event = stamped(.elicitation, detail: "", elicitation: request)
        let sink = sink
        let elicitationId = request.elicitationId
        let answer = await runPlane.awaitAnswer(
            to: request,
            runToken: holdingRunToken,
            posting: { await sink.post(event: event) },
            completing: { await sink.post(elicitationCompleted: elicitationId) },
            ending: { await sink.post(elicitationEnded: elicitationId, response: $0) }
        )
        return Self.checked(answer, to: request)
    }

    /// Ends the accepted URL flow of a question that the run of this context
    /// asked, and resumes the run with the accept.
    ///
    /// The flow ends only when the open question links to the run that holds
    /// this context. A question of another run, an unknown id, or a question
    /// with no accept gives ``ElicitationCompletionDelivery/noPendingElicitation``,
    /// and nothing changes. When the flow ends, the sink of the question gets
    /// ``OperationEventSink/post(elicitationCompleted:)``, as it does for a
    /// completion by the host through ``RunPlane/complete(elicitationId:)``.
    ///
    /// A run that waits in ``elicit(_:)`` cannot call this function from the
    /// same task. Another task of the tool calls it: for example, a callback
    /// handler that sees the end of the flow, or the notification handler of
    /// an MCP client that maps the wire id of the server to this elicitation
    /// id.
    ///
    /// - Parameter elicitationId: The id of the question.
    /// - Returns: ``ElicitationCompletionDelivery/completed`` when the flow
    ///   ended, or ``ElicitationCompletionDelivery/noPendingElicitation``.
    @discardableResult
    public func complete(elicitationId: ULID) async -> ElicitationCompletionDelivery {
        await runPlane.complete(elicitationId: elicitationId, runToken: holdingRunToken)
    }

    /// Gives `answer` to the run, or a decline when it is an accepted form
    /// answer whose content does not agree with the requested schema of
    /// `request`.
    ///
    /// - Parameters:
    ///   - answer: The answer that the run plane gave.
    ///   - request: The question of the answer.
    /// - Returns: `answer`, or a decline that tells why the content is not
    ///   valid.
    private static func checked(_ answer: ElicitationResponse, to request: ElicitationRequest) -> ElicitationResponse {
        guard request.mode == .form, answer.action == .accept,
            let schema = request.requestedSchema,
            let failure = schema.validationFailure(of: answer.content)
        else { return answer }
        return .decline(reason: ElicitationRequestedSchema.invalidAnswerReasonPrefix + failure)
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
    /// Each open question of the run ends first, with a cancel that gives
    /// ``RunPlane/runCancelledReason``. The questions of other runs stay
    /// open. The sink of each question gets
    /// ``OperationEventSink/post(elicitationEnded:response:)`` before the
    /// canceler runs, and a run that settles while those posts are in
    /// progress gives ``CancelOutcome/alreadySettled(_:)``.
    ///
    /// The questions of a settled or unknown token end in the same way. The
    /// token stays cancelled: each question that it asks after this call
    /// starts gets a cancel with ``RunPlane/runCancelledReason`` at once.
    ///
    /// This call waits for the end posts, and they wait on the sink chain of
    /// the run. Thus a sink must not await this call inside a post: the call
    /// then never returns. The run plane writes an error log at such a call.
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
    /// detail, because only THIS run gives its own terminal event. Each
    /// display event of a synchronous call goes through ``post(display:)``,
    /// so it also has the correlation of THIS run. Each record that a
    /// synchronous call attaches goes on THIS run.
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
        mount(
            tool, op: op, as: configuration,
            eventSink: MountedRunUpstreamSink(context: self), sessionSink: runSite.sessionSink)
    }

    /// This context, with `grace` as the settle period of each tool that it
    /// mounts. A host that configures its own settle period, for example a
    /// script runner, gives it to its inner calls this way.
    ///
    /// - Parameter grace: The settle period in seconds. A negative value acts
    ///   as `0`.
    /// - Returns: The changed context.
    public func settling(within grace: TimeInterval) -> ToolContext {
        var changed = self
        changed.runSite = runSite.settling(within: grace)
        return changed
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
        mount(tool, op: op, as: configuration, eventSink: sink, sessionSink: sink)
    }

    /// Mounts `tool` on a copy of the site of this run that posts to
    /// `eventSink` and `sessionSink`, and keeps the types of `tool`.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - op: The op of the mounted runs, or `nil` for the tool name.
    ///   - configuration: The mount when `tool` declares none.
    ///   - eventSink: The sink of each synchronous mounted run.
    ///   - sessionSink: The sink of each background mounted run.
    /// - Returns: The mounted tool, with the `Arguments` and `Output` of `tool`.
    private func mount<T: Tool>(
        _ tool: T,
        op: String?,
        as configuration: ToolMount,
        eventSink: any OperationEventSink,
        sessionSink: any OperationEventSink
    ) -> any Tool<T.Arguments, T.Output> {
        let site = runSite.posting(to: eventSink, sessionSink: sessionSink, op: op)
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
/// mounted. It posts each event and each display event through the mounting
/// context, so the event gets the correlation of the mounting run. It sends
/// each completion of a URL flow and each end of a question that the run
/// plane ended to the sink of the mounting context. It also
/// gives each record of a mounted call to the mounting context, so the
/// records go on the report of the mounting run.
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

    /// Posts `event` through the mounting context, so it gets the stamps of
    /// the mounting run.
    ///
    /// - Parameter event: The display event of the mounted run.
    func post(display event: ToolDisplayEvent) async {
        await context.post(display: event.kind)
    }

    /// Sends the completion of the URL flow of a question of the mounted run
    /// through the sink of the mounting context, the same path as the
    /// question.
    ///
    /// - Parameter elicitationId: The id of the question.
    func post(elicitationCompleted elicitationId: ULID) async {
        await context.postElicitationCompleted(elicitationId)
    }

    /// Sends the end of a question of the mounted run through the sink of
    /// the mounting context, the same path as the question, thus in order
    /// with the events of the mounting run.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - response: The answer that the run of the question gets.
    func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) async {
        await context.postElicitationEnded(elicitationId, response: response)
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
