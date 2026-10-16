import Foundation
import Logging
import Tracing
import ULID

/// The background runs of one session, and the questions that those runs ask.
///
/// Each session has its own run plane, and a fork gets a new one. The run
/// plane holds events and outcomes, never bulk output. A completion token
/// names a run: it is a ULID string, and it is also the `correlationID` of
/// each event of the run.
///
/// The host that makes the session states its ``userPresence`` one time. In
/// a ``UserPresence/headless`` session, each question ends at once with a
/// cancel that gives ``noUserPresentReason``: the question does not go to
/// the sink, and no question opens.
///
/// The run plane records two queues of queue metrics. Each run is one task
/// of the `run_plane` queue: it starts at once, and it completes when it
/// settles, with the bounded outcome of its terminal event. Each pending
/// elicitation is one task of the `elicitation` queue: its wait is the think
/// time of the user, thus it records a wait time and no run time. Each run
/// body runs in one ``ExtrasTelemetry/SpanName/run`` span, with one "enter"
/// log record, so a body that hangs shows an open span. No metric dimension
/// carries a completion token or an op, and no telemetry record carries a
/// progress detail, a terminal event or the content of an elicitation.
public actor RunPlane {
    /// What ``start(tool:op:kind:completionToken:canceler:tracer:body:)`` did.
    ///
    /// A test outside this package reads it through
    /// `@_spi(Testing) import FoundationModelsExtras`.
    @_spi(Testing)
    public enum StartResult: Sendable, Equatable {
        /// The run started, and the run plane tracks it.
        case started

        /// The token already names a run. The new run did not start.
        case duplicateToken
    }

    /// One open background run.
    private struct Run {
        /// The completion token of the run.
        let token: String

        /// The name of the tool that owns the run.
        let tool: String

        /// The `"verb noun"` op of the run.
        let op: String

        /// The kind of work of the run.
        let kind: RunKind

        /// The latest progress detail, or `nil` before the first progress.
        var latestProgressDetail: String?

        /// Asks the run to stop, and reports the outcome.
        let canceler: @Sendable () async -> OperationOutcome

        /// The waits for this run, by waiter id.
        var waiters: [UUID: Waiter] = [:]

        /// The queue ticket of the run, from its start. The settle of the
        /// run completes it.
        let ticket: QueueTicket
    }

    /// One ``wait(completionToken:seconds:)`` that waits for an open run.
    private struct Waiter {
        /// Resumes the wait. The run plane resumes it exactly one time.
        let continuation: CheckedContinuation<WaitOutcome, Never>

        /// Ends the wait at its deadline, or `nil` when it has no deadline.
        let deadline: Task<Void, Never>?

        /// Stops the deadline task, and resumes the wait with `outcome`.
        ///
        /// - Parameter outcome: The outcome of the wait.
        func resume(with outcome: WaitOutcome) {
            deadline?.cancel()
            continuation.resume(returning: outcome)
        }
    }

    /// One elicitation that waits for its answer.
    private struct Elicitation {
        /// The id of the elicitation.
        let id: ULID

        /// The completion token of the run that asked the question. The
        /// question stops that run until the user answers.
        let runToken: String

        /// The mode of the request.
        let mode: ElicitationMode

        /// The accept of a URL elicitation that waits for its completion.
        var accepted: ElicitationResponse?

        /// Tells the sink of the question that the accepted URL flow
        /// completed. Only the completion of an accepted URL flow starts it.
        let completing: @Sendable () async -> Void

        /// Tells the sink of the question that a cancel of the run plane
        /// ended the question, with the answer that the run gets. Only a
        /// cancel of the run plane starts it, after ``posting`` returned.
        let ending: @Sendable (ElicitationResponse) async -> Void

        /// The task that posts the elicitation event of the question. The
        /// end of the question waits for it, so the end comes after that
        /// event.
        let posting: Task<Void, Never>

        /// Gets the answer that resumes the run.
        let answer = Promise<ElicitationResponse>()

        /// The queue ticket of the elicitation, from the time it became
        /// pending. Its exit from the list completes it.
        let ticket: QueueTicket
    }

    /// Nanoseconds in one second.
    private static let nanosecondsPerSecond: Double = 1_000_000_000

    /// The reason of the cancel that a second question gets when an open
    /// question has the same `elicitationId`.
    static let duplicateElicitationIdReason = "an open elicitation already has this elicitationId"

    /// The reason of the cancel that each open question of a stopped run
    /// gets. ``cancel(completionToken:)``, ``sweep()`` and
    /// ``cancelOpenElicitations()`` give it, thus a host can tell this cancel
    /// from a cancel of the user.
    public static let runCancelledReason = "run cancelled"

    /// The text of the record when a sink awaits a cancel of the run plane
    /// inside a post.
    private static let cancelInsideSinkPostMessage =
        "a sink awaited a cancel of the run plane inside a post; the cancel waits for the end posts, and they wait for that post"

    /// The reason of the cancel that each question of a headless session
    /// gets at once. A host can tell this cancel from a cancel of the user.
    /// See ``UserPresence/headless``.
    public static let noUserPresentReason = "no user is present"

    /// The open runs, in start order.
    private var runs: [Run] = []

    /// The terminal event of each settled run, by completion token. The run
    /// plane keeps each one for the life of the session, so a late `wait` or
    /// `cancel` gets the terminal event, not `unknownToken`.
    private var settled: [String: OperationEvent] = [:]

    /// The pending elicitations, in the order they came.
    private var elicitations: [Elicitation] = []

    /// The id of each accepted URL question whose completion post is in
    /// progress, in the order of the completes. A question is here from the
    /// step that takes it off ``elicitations`` until its completion post
    /// returns, and it leaves before its run resumes.
    private var completingElicitationIds: [ULID] = []

    /// The id of each question whose end post is in progress, in the order
    /// that the cancels of the run plane ended them. A question is here from
    /// the step that takes it off ``elicitations`` until its end post
    /// returns, and it leaves before its run resumes.
    private var endingElicitationIds: [ULID] = []

    /// The task of each run body that did not end, by completion token. A
    /// run that the sweep settled stays here until its body ends, because a
    /// cancel of a ``RunKind/swiftTask`` run is only a request.
    /// ``joinRunBodies()`` waits for each one.
    private var bodies: [String: Task<Void, Never>] = [:]

    /// Whether a ``sweep()`` runs now. A second sweep at the same time
    /// returns nothing.
    private var isSweeping = false

    /// The recorder of the queue metrics of the runs. A run is enqueued and
    /// started at once, and its settle completes it.
    private let runTelemetry = QueueTelemetry(name: .runPlane)

    /// The recorder of the queue metrics of the pending elicitations. An
    /// elicitation is enqueued when it becomes pending and is never started,
    /// thus its wait time is the think time of the user and it records no
    /// run time.
    private let elicitationTelemetry = QueueTelemetry(name: .elicitation)

    /// Gets the terminal event of each run that settles by itself. Weak,
    /// because the observer is the session that owns this run plane.
    private weak var settlementObserver: (any BackgroundRunSettlementObserver)?

    /// The clock of the timers of the runs: the deadline of each wait, the
    /// timeout of each run, and the settle period of each background call.
    public nonisolated let clock: any RunClock

    /// Tells if a user can answer the questions of the session. The value is
    /// fixed for the life of the run plane, which is the life of one session.
    public nonisolated let userPresence: UserPresence

    /// Makes an empty run plane.
    ///
    /// - Parameters:
    ///   - clock: The clock of the timers of the runs. The default is
    ///     ``ContinuousRunClock``, the real time. A test gives a
    ///     ``ManualRunClock``.
    ///   - userPresence: Tells if a user can answer the questions of the
    ///     session. The default is ``UserPresence/interactive``. A host that
    ///     runs a session with no user gives ``UserPresence/headless``.
    public init(clock: any RunClock = ContinuousRunClock(), userPresence: UserPresence = .interactive) {
        self.clock = clock
        self.userPresence = userPresence
    }

    /// A new completion token: a ULID string.
    ///
    /// - Returns: The token.
    public static func makeCompletionToken() -> String {
        ULID().ulidString
    }

    // MARK: - Background runs

    /// Starts `body` as a background run under `completionToken`.
    ///
    /// This method does not suspend, so the run is on the list before its
    /// body can settle it. The body runs in a new task, outside this actor,
    /// with the task-local values of the caller. When the body returns, the
    /// run settles: each wait resumes with the terminal event, and the
    /// observer gets it. A run that the sweep removed settles with no
    /// delivery, so each run has one terminal event.
    ///
    /// A host starts a run through ``ToolMounting``. A test outside this
    /// package calls this method directly through
    /// `@_spi(Testing) import FoundationModelsExtras`.
    ///
    /// - Parameters:
    ///   - tool: The name of the tool that owns the run.
    ///   - op: The `"verb noun"` op of the run.
    ///   - kind: The kind of work of the run.
    ///   - completionToken: The completion token of the run.
    ///   - canceler: Asks the run to stop and reports the outcome, or `nil`
    ///     for the cooperative canceler: it cancels the task of the body and
    ///     reports ``OperationOutcome/cancelled``.
    ///   - tracer: The tracer of the session for the span of the run body,
    ///     or `nil` for `InstrumentationSystem.tracer` at call time. The
    ///     default is `nil`.
    ///   - body: The work. It returns the terminal event of the run.
    /// - Returns: ``StartResult/duplicateToken`` when the token names a run.
    @discardableResult
    @_spi(Testing)
    public func start(
        tool: String,
        op: String,
        kind: RunKind,
        completionToken: String,
        canceler: (@Sendable () async -> OperationOutcome)?,
        tracer: (any Tracer)? = nil,
        body: @escaping @Sendable () async -> OperationEvent
    ) -> StartResult {
        guard index(of: completionToken) == nil, settled[completionToken] == nil else {
            return .duplicateToken
        }
        var ticket = runTelemetry.enqueued()
        runTelemetry.started(&ticket)
        let work = Task { [weak self] in
            let terminal = await Self.runTraced(
                body, tool: tool, op: op, kind: kind, completionToken: completionToken, tracer: tracer)
            await self?.settleByItself(completionToken, with: terminal)
            await self?.endBody(completionToken)
        }
        // No suspension point since the task started, so the task cannot
        // remove its entry before this line adds it.
        bodies[completionToken] = work
        let cooperative: @Sendable () async -> OperationOutcome = {
            work.cancel()
            return .cancelled
        }
        runs.append(
            Run(
                token: completionToken, tool: tool, op: op, kind: kind, canceler: canceler ?? cooperative,
                ticket: ticket))
        return .started
    }

    /// Installs the observer that gets the terminal event of each run that
    /// settles by itself from now on.
    ///
    /// - Parameter settlementObserver: The observer.
    public func attach(settlementObserver: any BackgroundRunSettlementObserver) {
        self.settlementObserver = settlementObserver
    }

    /// Records the latest progress detail of a run. An unknown token does
    /// nothing.
    ///
    /// A run reports its progress through ``ToolContext``. A test outside
    /// this package calls this method directly through
    /// `@_spi(Testing) import FoundationModelsExtras`.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - detail: The progress detail.
    @_spi(Testing)
    public func updateProgress(completionToken: String, detail: String) {
        guard let index = index(of: completionToken) else { return }
        runs[index].latestProgressDetail = detail
    }

    /// The completion tokens of the settled runs.
    ///
    /// - Returns: The tokens.
    public func settledRunTokens() -> Set<String> {
        Set(settled.keys)
    }

    /// Each open run, in start order.
    ///
    /// - Returns: The runs, with no output.
    public func backgroundRuns() -> [BackgroundRun] {
        runs.map(Self.backgroundRun(of:))
    }

    /// Each open run that waits only for the user, in start order.
    ///
    /// A run waits only for the user when one or more of its questions are
    /// open. Each question stops the run until the user answers, thus the
    /// open work of the run is its questions. A run that waits for a process
    /// or for another run has no open question, and is not in the list. The
    /// run plane does not see work that a run body does at the same time as
    /// its question.
    ///
    /// A host does not count these runs as work of the session. Each
    /// question that a run asks links to the run through
    /// ``OpenElicitation/runToken``.
    ///
    /// - Returns: The runs, with no output.
    public func runsWaitingOnlyForUser() -> [BackgroundRun] {
        let askingRunTokens = Set(elicitations.map(\.runToken))
        return runs.filter { askingRunTokens.contains($0.token) }.map(Self.backgroundRun(of:))
    }

    /// The public view of an open run.
    ///
    /// - Parameter run: The open run.
    /// - Returns: The run, with no output.
    private static func backgroundRun(of run: Run) -> BackgroundRun {
        BackgroundRun(
            completionToken: run.token,
            tool: run.tool,
            op: run.op,
            kind: run.kind,
            latestProgressDetail: run.latestProgressDetail
        )
    }

    /// Waits until a run settles, with a deadline or with none.
    ///
    /// A settled run answers at once. An unknown token does nothing. A cancel
    /// of the calling task ends the wait with ``WaitOutcome/cancelled``.
    ///
    /// The run keeps the wait by id until the settlement, the deadline or the
    /// cancel ends it, and then removes it. The first of the three resumes
    /// the wait, and the other two find no wait and do nothing.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - seconds: The deadline, as given. NaN and a negative value become
    ///     zero. `nil` sets no deadline.
    /// - Returns: The ``WaitOutcome``.
    public func wait(completionToken: String, seconds: Double?) async -> WaitOutcome {
        if let terminal = settled[completionToken] {
            return .settled(terminal)
        }
        guard index(of: completionToken) != nil else {
            return .unknownToken
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                addWaiter(waiterID, resuming: continuation, to: completionToken, deadline: seconds)
            }
        } onCancel: {
            // The end runs on this actor after `addWaiter`, so it finds the
            // wait also when the cancel came first.
            Task { await self.endWaiter(waiterID, of: completionToken, with: .cancelled) }
        }
    }

    /// The number of waits that wait now for the open run of
    /// `completionToken`. Zero for a settled or unknown token.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The count.
    func waiterCount(completionToken: String) -> Int {
        guard let index = index(of: completionToken) else { return 0 }
        return runs[index].waiters.count
    }

    /// Ends the open questions of a run, then runs the canceler of the run
    /// and reports its outcome as is. The run stays open until it settles.
    ///
    /// Each open question that the run asked gets a cancel with
    /// ``runCancelledReason``. A question of a synchronous call that the run
    /// mounted links to the run, thus it ends too. The questions of other
    /// runs stay open. The questions end before the canceler runs, because a
    /// run that waits for an answer cannot settle, and a canceler that waits
    /// for the run to stop then never returns.
    ///
    /// A question whose accepted URL flow ``complete(elicitationId:)`` ended
    /// left the list already, also while its completion post is in progress.
    /// This call does not end that question: its run gets the accept when the
    /// post returns.
    ///
    /// The order is fixed. The questions of the run leave the list in one
    /// step, as ``cancelOpenElicitations()`` tells. The sink of each question
    /// gets ``OperationEventSink/post(elicitationEnded:response:)`` after the
    /// elicitation event of the question. The run gets the cancel only after
    /// that post returned, and the canceler runs only after each end post
    /// returned. The run can settle while the end posts are in progress.
    /// Then this call finds the run again after the posts, and gives
    /// ``CancelOutcome/alreadySettled(_:)`` with no call of the canceler.
    ///
    /// This call waits for the end posts, and they wait on the sink chain of
    /// the run. Thus a sink must not await this call inside a post: the call
    /// then never returns. The run plane writes an error log at such a call.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: ``CancelOutcome/reported(_:)``, or
    ///   ``CancelOutcome/alreadySettled(_:)`` when the run settled first, also
    ///   while the end posts were in progress, or
    ///   ``CancelOutcome/unknownToken``.
    func cancel(completionToken: String) async -> CancelOutcome {
        Self.checkNotInSinkPost()
        if case .closed(let outcome) = cancelTarget(of: completionToken) {
            return outcome
        }
        await cancelQuestions(ofRun: completionToken)
        // The end posts suspend this actor, so the run can settle by itself
        // in that time. Thus the run is found again.
        switch cancelTarget(of: completionToken) {
        case .closed(let outcome):
            return outcome
        case .open(let canceler):
            return .reported(await canceler())
        }
    }

    // MARK: - Pending elicitations

    /// Suspends the calling run until its elicitation gets an answer. An
    /// accepted URL elicitation also waits for ``complete(elicitationId:)``.
    ///
    /// A headless run plane (see ``userPresence``) gives a cancel with
    /// ``noUserPresentReason`` at once. Then `posting` does not run, no
    /// elicitation becomes pending, and nothing waits.
    ///
    /// The elicitation is pending before `posting` runs. A duplicate
    /// `elicitationId` gets a cancel with ``duplicateElicitationIdReason``
    /// at once, and `posting` does not run. The open question with that id
    /// does not change.
    ///
    /// The answer of the host comes back unchanged: a decline or a cancel
    /// keeps its ``ElicitationResponse/reason``.
    ///
    /// - Parameters:
    ///   - request: The request. Its `elicitationId` names the elicitation.
    ///   - runToken: The completion token of the run that asks. The
    ///     elicitation links to that run until it leaves the list.
    ///   - posting: Sends the request to the host.
    ///   - completing: Tells the host that the accepted URL flow completed.
    ///     The run plane starts it only when ``complete(elicitationId:)``
    ///     completes an accepted URL flow. No other end of the question
    ///     starts it. The run gets the accept only after `completing`
    ///     returns, thus the completion is posted before the run resumes.
    ///   - ending: Tells the host that a cancel of the run plane ended the
    ///     question, with the answer that the run gets. The run plane starts
    ///     it only when ``cancel(completionToken:)``, ``sweep()`` or
    ///     ``cancelOpenElicitations()`` ends the open question, and only
    ///     after `posting` returned. The run gets the cancel only after
    ///     `ending` returns, thus the end is posted after the question and
    ///     before the run resumes.
    /// - Returns: The answer of the user.
    func awaitAnswer(
        to request: ElicitationRequest,
        runToken: String,
        posting: @escaping @Sendable () async -> Void = {},
        completing: @escaping @Sendable () async -> Void = {},
        ending: @escaping @Sendable (ElicitationResponse) async -> Void = { _ in }
    ) async -> ElicitationResponse {
        guard userPresence == .interactive else {
            return .cancel(reason: Self.noUserPresentReason)
        }
        guard elicitationIndex(of: request.elicitationId) == nil else {
            return .cancel(reason: Self.duplicateElicitationIdReason)
        }
        // The question goes on the list in this step, before this actor can
        // run a call of the posting task, so the question is pending before
        // `posting` can answer it.
        let elicitation = Elicitation(
            id: request.elicitationId, runToken: runToken, mode: request.mode, completing: completing,
            ending: ending, posting: Task { await posting() }, ticket: elicitationTelemetry.enqueued())
        elicitations.append(elicitation)
        return await elicitation.answer.value
    }

    /// The ids of the pending elicitations, in the order they came.
    ///
    /// - Returns: The ids.
    func pendingElicitationIds() -> [ULID] {
        elicitations.map(\.id)
    }

    /// Each pending elicitation, with the run that asked it, in the order
    /// they came. An accepted URL elicitation stays in the list until its
    /// completion.
    ///
    /// When ``complete(elicitationId:)`` completes an accepted URL flow, the
    /// question leaves this list and goes into ``completingElicitations()``
    /// in the same step. Thus, while its completion post is in progress, each
    /// read finds the question in one of the two lists. In the same way, when
    /// a cancel of the run plane ends an open question, the question leaves
    /// this list and goes into ``endingElicitations()`` in the same step.
    ///
    /// - Returns: The open elicitations.
    public func openElicitations() -> [OpenElicitation] {
        elicitations.map { OpenElicitation(elicitationId: $0.id, runToken: $0.runToken) }
    }

    /// The id of each question whose completion post is in progress, in the
    /// order of the completes.
    ///
    /// A question goes into this list in the same step as
    /// ``complete(elicitationId:)`` takes it off ``openElicitations()``. It
    /// leaves this list when its post of
    /// ``OperationEventSink/post(elicitationCompleted:)`` returns, before its
    /// run resumes with the accept. Thus a host can tell a completion that is
    /// on its way from a question that a run cancel ended: a question that a
    /// run cancel or a ``sweep()`` ended is not in this list. It is in
    /// ``endingElicitations()`` while its end post is in progress. A read
    /// after the run resumed does not find the question in this list.
    ///
    /// - Returns: The ids.
    public func completingElicitations() -> [ULID] {
        completingElicitationIds
    }

    /// The id of each question whose end post is in progress, in the order
    /// that the cancels of the run plane ended them.
    ///
    /// A question goes into this list in the same step as a cancel of the
    /// run plane (``cancel(completionToken:)``, ``sweep()`` or
    /// ``cancelOpenElicitations()``) takes it off ``openElicitations()``. It
    /// leaves this list when its post of
    /// ``OperationEventSink/post(elicitationEnded:response:)`` returns,
    /// before its run resumes with the cancel. Thus, while the end post is in
    /// progress, each read finds the question in this list and not in
    /// ``openElicitations()``. A read after the run resumed finds the
    /// question in neither list.
    ///
    /// - Returns: The ids.
    public func endingElicitations() -> [ULID] {
        endingElicitationIds
    }

    /// Ends each open question with a cancel that gives
    /// ``runCancelledReason``, and returns their ids.
    ///
    /// A host calls this when it cancels all the work of the session, or
    /// when it closes, so the run plane ends each question and posts the end.
    /// The run of each question gets the cancel; the run itself does not
    /// stop.
    ///
    /// The order is fixed. Each open question leaves ``openElicitations()``
    /// and goes into ``endingElicitations()`` in one step, with no
    /// suspension. Thus an answer (``respond(elicitationId:_:)``) or a
    /// completion (``complete(elicitationId:)``) that comes before this step
    /// wins, and the run plane posts no end for that question. An answer or
    /// a completion that comes after this step gives
    /// ``ElicitationAnswerDelivery/noPendingElicitation`` or
    /// ``ElicitationCompletionDelivery/noPendingElicitation``. Then, one
    /// question at a time in the order they came, the sink of the question
    /// gets ``OperationEventSink/post(elicitationEnded:response:)`` after the
    /// post of its elicitation event returned. The run gets the cancel only
    /// after the end post returned. A question whose completion post is in
    /// progress (``completingElicitations()``) is not open: it gets no end,
    /// and its run gets the accept.
    ///
    /// This call waits for the end posts, and they wait on the sink chain of
    /// each run. Thus a sink must not await this call inside a post: the call
    /// then never returns. A debug build stops at such a call.
    ///
    /// - Returns: The ids of the questions that ended, in the order they
    ///   came. The call returns only after each end post returned.
    public func cancelOpenElicitations() async -> [ULID] {
        Self.checkNotInSinkPost()
        return await cancelQuestions { _ in true }
    }

    /// Gives the answer of the user to a pending elicitation.
    ///
    /// A URL accept keeps the elicitation open until
    /// ``complete(elicitationId:)``. Each other answer resumes the run. The
    /// run gets the answer unchanged, thus a decline or a cancel keeps its
    /// ``ElicitationResponse/reason``. An unknown or answered id does
    /// nothing, and so does the id of a question that a cancel of the run
    /// plane ended.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the elicitation.
    ///   - response: The answer.
    /// - Returns: The ``ElicitationAnswerDelivery``.
    @discardableResult
    public func respond(elicitationId: ULID, _ response: ElicitationResponse) -> ElicitationAnswerDelivery {
        guard let index = elicitationIndex(of: elicitationId), elicitations[index].accepted == nil else {
            return .noPendingElicitation
        }
        if elicitations[index].mode == .url && response.action == .accept {
            elicitations[index].accepted = response
            return .acceptedAwaitingCompletion
        }
        finish(elicitations.remove(at: index), with: response)
        return .delivered
    }

    /// Tells that the flow of an accepted URL elicitation ended, and resumes
    /// the run. An unknown id, or one with no accept, does nothing.
    ///
    /// When the flow ends, the sink of the question gets
    /// ``OperationEventSink/post(elicitationCompleted:)`` in a new task, in
    /// the same way as the sink gets the event of a new question. A host
    /// reports it, for example as the end of the URL flow to the client.
    ///
    /// The completion is posted before the run resumes: the task resumes the
    /// run with the accept only after that post returned. Thus the sink gets
    /// the completion before each post of the resumed run.
    ///
    /// This method does not wait for that task. The question leaves the list
    /// at once, and the method returns at once. Thus a second call gives
    /// ``ElicitationCompletionDelivery/noPendingElicitation``. A run cancel
    /// (``cancel(completionToken:)``) or a ``sweep()`` that comes before the
    /// run resumes does not find the question and gives it no cancel: the run
    /// gets one answer only, the accept, when the post returns. A sink whose
    /// post does not return keeps the run waiting.
    ///
    /// While the post is in progress, ``completingElicitations()`` gives the
    /// id of the question. The question goes into that list in the same step
    /// as it leaves the list of ``openElicitations()``, and it leaves that
    /// list when the post returns, before the run resumes.
    ///
    /// - Parameter elicitationId: The id of the elicitation.
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    public func complete(elicitationId: ULID) -> ElicitationCompletionDelivery {
        completeAccepted(elicitationId: elicitationId, linkedTo: nil)
    }

    /// Completes an accepted URL elicitation as ``complete(elicitationId:)``
    /// does, but only when the elicitation links to the run of `runToken`.
    /// An elicitation of another run does not change.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the elicitation.
    ///   - runToken: The completion token of the run that must hold the
    ///     elicitation.
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    func complete(elicitationId: ULID, runToken: String) -> ElicitationCompletionDelivery {
        completeAccepted(elicitationId: elicitationId, linkedTo: runToken)
    }

    // MARK: - The sweep

    /// The sweep at the end of a session: cancels each open run in start
    /// order, gives one terminal event for each, then ends each pending
    /// elicitation that is still open.
    ///
    /// Each pending elicitation gets a cancel with ``runCancelledReason``.
    /// The sweep ends the questions of each run before it runs the canceler
    /// of that run, because a run that waits for an answer cannot settle,
    /// and a canceler that waits for the run to stop then never returns.
    ///
    /// A question whose accepted URL flow ``complete(elicitationId:)`` ended
    /// left the list already, also while its completion post is in progress.
    /// The sweep does not end that question: its run gets the accept when the
    /// post returns.
    ///
    /// The order is the order of ``cancel(completionToken:)``, for each run:
    /// the sink of each question gets
    /// ``OperationEventSink/post(elicitationEnded:response:)`` after the
    /// elicitation event of the question, the run gets the cancel after that
    /// post returned, and the canceler of the run runs only after each end
    /// post of the run returned. A run that settles by itself while its end
    /// posts or its canceler are in progress gives its own terminal event.
    /// The questions that are still open at the end get their end posts
    /// before this call returns.
    ///
    /// This call waits for the end posts, and they wait on the sink chain of
    /// each run. Thus a sink must not await this call inside a post: the call
    /// then never returns. A debug build stops at such a call.
    ///
    /// - Returns: One terminal event for each run that was open when the
    ///   sweep started. A sweep while another sweep runs returns nothing.
    public func sweep() async -> [OperationEvent] {
        Self.checkNotInSinkPost()
        guard !isSweeping else { return [] }
        isSweeping = true
        defer { isSweeping = false }
        var terminals: [OperationEvent] = []
        for token in runs.map(\.token) where index(of: token) != nil {
            if let terminal = await sweepRun(token) {
                terminals.append(terminal)
            }
        }
        await cancelQuestions { _ in true }
        return terminals
    }

    /// Ends the open questions of the run of `token`, runs its canceler, and
    /// settles the run with the outcome of the canceler.
    ///
    /// The end posts and the canceler suspend this actor, so the run can
    /// settle by itself in that time. Its own terminal event is then the one
    /// terminal event of the run, and a run that settled during the end
    /// posts gets no call of its canceler.
    ///
    /// - Parameter token: The completion token of an open run.
    /// - Returns: The one terminal event of the run, or `nil` when the run
    ///   is not open and not settled.
    private func sweepRun(_ token: String) async -> OperationEvent? {
        await cancelQuestions(ofRun: token)
        if let own = settled[token] {
            return own
        }
        guard let index = index(of: token) else {
            assertionFailure("a swept run is neither open nor settled")
            ExtrasTelemetry.makeLogger().error("a swept run is neither open nor settled; it gives no terminal event")
            return nil
        }
        let run = runs[index]
        let outcome = await run.canceler()
        if let own = settled[token] {
            return own
        }
        let swept = OperationEvent(
            tool: run.tool,
            op: run.op,
            correlationID: token,
            kind: .completed,
            detail: run.latestProgressDetail ?? "",
            outcome: outcome
        )
        settle(token, with: swept)
        return swept
    }

    /// Waits until the body of each run ended: each run that is open, each
    /// run that the sweep settled while its body continued, and each run that
    /// starts while this call waits. A body that ended is gone at once.
    ///
    /// This call cancels nothing. Call ``sweep()`` first to stop the open
    /// runs: then this call waits for each body to see its cancel. A body
    /// that does not stop keeps this call waiting. A cancel of the calling
    /// task does not end the wait, so a caller that must stop waiting runs
    /// this call in a task of its own.
    public func joinRunBodies() async {
        while let body = bodies.values.first {
            await body.value
        }
    }

    // MARK: - Helpers

    /// Removes the task of the body of `token`, which ended.
    ///
    /// - Parameter token: The completion token of the run.
    private func endBody(_ token: String) {
        bodies[token] = nil
    }

    /// Converts seconds to the nanoseconds that `Task.sleep(nanoseconds:)`
    /// takes. NaN and a negative value give zero, and a value that `UInt64`
    /// cannot hold, infinity also, gives `UInt64.max`.
    ///
    /// - Parameter seconds: The duration in seconds.
    /// - Returns: The duration in nanoseconds.
    static func boundedNanoseconds(clamping seconds: Double) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        let nanoseconds = seconds * nanosecondsPerSecond
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds)
    }

    /// Converts seconds to a `Duration` for the ``clock``, with the same
    /// limits as ``boundedNanoseconds(clamping:)``.
    ///
    /// - Parameter seconds: The duration in seconds.
    /// - Returns: The duration.
    static func boundedDuration(clamping seconds: Double) -> Duration {
        .nanoseconds(boundedNanoseconds(clamping: seconds))
    }

    /// Keeps a wait on the open run of `token` under `id`. A deadline starts
    /// one task that ends the wait when the deadline elapses; the resume of
    /// the wait cancels that task. A run that is not open answers at once.
    ///
    /// - Parameters:
    ///   - id: The id of the wait.
    ///   - continuation: Resumes the wait.
    ///   - token: The completion token of the run.
    ///   - seconds: The deadline, or `nil` for none.
    private func addWaiter(
        _ id: UUID,
        resuming continuation: CheckedContinuation<WaitOutcome, Never>,
        to token: String,
        deadline seconds: Double?
    ) {
        guard let index = index(of: token) else {
            continuation.resume(returning: settled[token].map(WaitOutcome.settled) ?? .unknownToken)
            return
        }
        let clock = clock
        let deadline = seconds.map { seconds in
            // The end comes from the clock now, not when the task starts.
            let end = clock.now.advanced(by: Self.boundedDuration(clamping: seconds))
            return Task { [weak self] in
                do {
                    try await clock.sleep(until: end)
                } catch {
                    return
                }
                await self?.endWaiter(id, of: token, with: .deadlineElapsed)
            }
        }
        runs[index].waiters[id] = Waiter(continuation: continuation, deadline: deadline)
    }

    /// Removes the wait `id` from the open run of `token`, and resumes it
    /// with `outcome`. A wait that already ended does nothing.
    ///
    /// - Parameters:
    ///   - id: The id of the wait.
    ///   - token: The completion token of the run.
    ///   - outcome: The outcome of the wait.
    private func endWaiter(_ id: UUID, of token: String, with outcome: WaitOutcome) {
        guard let index = index(of: token), let waiter = runs[index].waiters.removeValue(forKey: id) else {
            return
        }
        waiter.resume(with: outcome)
    }

    /// Settles a run whose body returned, and gives its terminal event to
    /// the observer. A run that the sweep removed is dropped.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - terminal: The terminal event from the body.
    private func settleByItself(_ token: String, with terminal: OperationEvent) async {
        guard settle(token, with: terminal) else { return }
        await settlementObserver?.deliver(settledTerminal: terminal)
    }

    /// Moves an open run to the settled runs, records the completion of its
    /// queue task, and resumes each wait for it.
    ///
    /// This is the one place where a run leaves the open runs, thus each run
    /// records one completion only: the settle by the body and the settle by
    /// the sweep both come here, and the later one finds no open run.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - terminal: The terminal event of the run.
    /// - Returns: `false` when the run is not open.
    @discardableResult
    private func settle(_ token: String, with terminal: OperationEvent) -> Bool {
        guard let index = index(of: token) else { return false }
        let run = runs.remove(at: index)
        settled[token] = terminal
        runTelemetry.completed(run.ticket, outcome: Self.queueOutcome(of: terminal))
        for waiter in run.waiters.values {
            waiter.resume(with: .settled(terminal))
        }
        return true
    }

    /// Gives the bounded queue outcome of the terminal event of a run.
    ///
    /// - Parameter terminal: The terminal event of the run.
    /// - Returns: The telemetry value of the outcome of the event. An event
    ///   with no outcome gives ``QueueOutcome/lost``, as the tool-call
    ///   metrics do.
    private static func queueOutcome(of terminal: OperationEvent) -> QueueOutcome {
        ExtrasTelemetry.telemetryOutcome(of: terminal.outcome ?? ToolCallSpan.outcomeOfTerminalWithNoOutcome)
    }

    /// Records the completion of `elicitation`, then gives `response` to the
    /// run that waits for it. Call this one time for each elicitation that
    /// leaves the list.
    ///
    /// - Parameters:
    ///   - elicitation: The elicitation that left the list.
    ///   - response: The answer that resumes the run.
    private func finish(_ elicitation: Elicitation, with response: ElicitationResponse) {
        elicitationTelemetry.completed(elicitation.ticket, outcome: Self.queueOutcome(of: response))
        elicitation.answer.fulfill(response)
    }

    /// Ends the accepted URL flow of `elicitationId`: the question leaves the
    /// list at once, and one task posts the completion event of the question
    /// and only after that resumes the run with the accept. This is the one
    /// place that starts that event.
    ///
    /// The question is off the list before this method returns, thus a second
    /// completion, a run cancel and the sweep do not find it, and the run gets
    /// one answer only: the accept.
    ///
    /// The id goes into ``completingElicitationIds`` in the same step as the
    /// question leaves the list. The task removes the id after the post
    /// returns and before it resumes the run, with no suspension between the
    /// two, so no read sees the id after the run has its answer.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the elicitation.
    ///   - runToken: The completion token of the run that must hold the
    ///     elicitation, or `nil` for any run.
    /// - Returns: ``ElicitationCompletionDelivery/completed``, or
    ///   ``ElicitationCompletionDelivery/noPendingElicitation`` when no
    ///   accepted URL elicitation with this id links to the run.
    private func completeAccepted(elicitationId: ULID, linkedTo runToken: String?) -> ElicitationCompletionDelivery {
        guard let index = elicitationIndex(of: elicitationId),
            runToken == nil || elicitations[index].runToken == runToken,
            let accepted = elicitations[index].accepted
        else {
            return .noPendingElicitation
        }
        let elicitation = elicitations.remove(at: index)
        completingElicitationIds.append(elicitation.id)
        Task {
            await elicitation.completing()
            Self.removeFirst(elicitation.id, from: &completingElicitationIds, for: .completion)
            finish(elicitation, with: accepted)
        }
        return .completed
    }

    /// A post of the run plane that keeps the id of its question in a list
    /// while the post is in progress.
    private enum TrackedPost {
        /// The completion post of an accepted URL flow, tracked in
        /// ``completingElicitationIds``.
        case completion

        /// The end post of a question that a cancel of the run plane ended,
        /// tracked in ``endingElicitationIds``.
        case end

        /// The text of the record when the post ends for an id that is not
        /// in its list.
        var missingIdMessage: String {
            switch self {
            case .completion: "a completion post ended for an id that is not completing"
            case .end: "an end post ended for an id that is not ending"
            }
        }
    }

    /// Removes the first `elicitationId` from `ids`, because the post of
    /// the question returned. Only the first one goes, because a new
    /// question can use the same id while this post is in progress, and its
    /// own post then adds the id again.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - ids: The list of the posts in progress.
    ///   - post: The post that returned.
    private static func removeFirst(_ elicitationId: ULID, from ids: inout [ULID], for post: TrackedPost) {
        guard let index = ids.firstIndex(of: elicitationId) else {
            assertionFailure(post.missingIdMessage)
            ExtrasTelemetry.makeLogger().error("\(post.missingIdMessage); nothing to remove")
            return
        }
        ids.remove(at: index)
    }

    /// Ends each open question of the run of `token` with a cancel that gives
    /// ``runCancelledReason``, as ``cancelQuestions(where:)`` does. The
    /// questions of other runs stay open.
    ///
    /// - Parameter token: The completion token of the run.
    private func cancelQuestions(ofRun token: String) async {
        await cancelQuestions { $0.runToken == token }
    }

    /// Ends each open question that `isEnded` selects with a cancel that
    /// gives ``runCancelledReason``, in the order they came. The other
    /// questions stay open.
    ///
    /// In one step with no suspension, the selected questions leave
    /// ``elicitations`` and go into ``endingElicitationIds``. Thus an answer
    /// or a completion after this step finds no question. Then, one question
    /// at a time: the end waits until the post of the elicitation event of
    /// the question returned, so the end comes after that event. It posts the
    /// end, and only after that post returned it removes the id and resumes
    /// the run with the cancel, with no suspension between the two.
    ///
    /// - Parameter isEnded: Selects each question to end.
    /// - Returns: The ids of the questions that ended, in the order they
    ///   came, after each end post returned.
    @discardableResult
    private func cancelQuestions(where isEnded: (Elicitation) -> Bool) async -> [ULID] {
        let ended = elicitations.filter(isEnded)
        elicitations.removeAll(where: isEnded)
        endingElicitationIds.append(contentsOf: ended.map(\.id))
        let response = ElicitationResponse.cancel(reason: Self.runCancelledReason)
        for elicitation in ended {
            await elicitation.posting.value
            await elicitation.ending(response)
            Self.removeFirst(elicitation.id, from: &endingElicitationIds, for: .end)
            finish(elicitation, with: response)
        }
        return ended.map(\.id)
    }

    /// What a cancel of a run finds now.
    private enum CancelTarget {
        /// The run is open. The cancel runs this canceler of the run.
        case open(canceler: @Sendable () async -> OperationOutcome)

        /// No run is open. The cancel reports this outcome.
        case closed(CancelOutcome)
    }

    /// What a cancel of the run of `token` finds now: the canceler of the
    /// open run, or the outcome of a settled or unknown run.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The ``CancelTarget``.
    private func cancelTarget(of token: String) -> CancelTarget {
        if let terminal = settled[token] {
            return .closed(.alreadySettled(terminal))
        }
        guard let index = index(of: token) else {
            return .closed(.unknownToken)
        }
        return .open(canceler: runs[index].canceler)
    }

    /// Writes an error log when the current task is in a post to a sink of
    /// the session.
    ///
    /// A cancel of the run plane waits for the end posts, and they wait on
    /// the sink chain of the run. A sink that awaits such a cancel inside a
    /// post thus waits for itself, and neither the post nor the cancel
    /// returns. The check only logs and does not stop a debug build: see
    /// ``SinkPost`` for why the mark can be set with no deadlock.
    private static func checkNotInSinkPost() {
        guard SinkPost.isInProgress else { return }
        ExtrasTelemetry.makeLogger().error("\(cancelInsideSinkPostMessage)")
    }

    /// Gives the bounded queue outcome of the answer to an elicitation.
    ///
    /// - Parameter response: The answer.
    /// - Returns: ``QueueOutcome/succeeded`` for an accept or a decline,
    ///   because the user gave an answer, and ``QueueOutcome/cancelled`` for
    ///   a cancel, which is also the answer of the sweep.
    private static func queueOutcome(of response: ElicitationResponse) -> QueueOutcome {
        switch response.action {
        case .accept, .decline: .succeeded
        case .cancel: .cancelled
        }
    }

    /// Runs `body` in one ``ExtrasTelemetry/SpanName/run`` span, and writes one
    /// "enter" log record before the body starts.
    ///
    /// The span and the record carry the tool name, the run kind and the
    /// completion token only. They never carry the op, a progress detail or
    /// the terminal event. A body that does not return keeps its span open,
    /// and its "enter" record shows the hung run. The span uses `tracer`, the
    /// tracer of the session. When `tracer` is `nil`, the span uses
    /// `InstrumentationSystem.tracer` at call time, thus the task-local
    /// tracer. In both cases the span has the span of the caller as its
    /// parent, because the task of the body inherits it.
    ///
    /// - Parameters:
    ///   - body: The work of the run.
    ///   - tool: The name of the tool that owns the run.
    ///   - op: The op of the run, for the terminal event of the fallback only.
    ///   - kind: The kind of work of the run.
    ///   - completionToken: The completion token of the run.
    ///   - tracer: The tracer of the session, or `nil` for
    ///     `InstrumentationSystem.tracer` at call time.
    /// - Returns: The terminal event of `body`.
    private static func runTraced(
        _ body: @Sendable () async -> OperationEvent,
        tool: String,
        op: String,
        kind: RunKind,
        completionToken: String,
        tracer: (any Tracer)?
    ) async -> OperationEvent {
        let logger = ExtrasTelemetry.makeLogger()
        do {
            return try await TracedCall.run(
                ExtrasTelemetry.SpanName.run,
                tracer: tracer,
                logger: logger,
                attributes: { attributes in
                    attributes[ExtrasTelemetry.AttributeKey.toolName] = tool
                    attributes[ExtrasTelemetry.AttributeKey.backgroundRunKind] = kind.rawValue
                    attributes[ExtrasTelemetry.AttributeKey.completionToken] = completionToken
                },
                metadata: [
                    ExtrasTelemetry.LogMetadataKey.toolName: .string(tool),
                    ExtrasTelemetry.LogMetadataKey.backgroundRunKind: .string(kind.rawValue),
                    ExtrasTelemetry.LogMetadataKey.completionToken: .string(completionToken),
                ]
            ) { _ in
                await body()
            }
        } catch {
            // `TracedCall.run` throws only the error of its body, and `body`
            // does not throw. The type of `TracedCall.run` still admits an
            // error, thus the run settles as lost if one ever comes.
            assertionFailure("the span of a run body threw, but the body does not throw")
            logger.error(
                "the span of a run body threw; the run settles as lost",
                metadata: [ExtrasTelemetry.AttributeKey.errorType: .string(ExtrasTelemetry.errorType(of: error))])
            return OperationEvent(
                tool: tool, op: op, correlationID: completionToken, kind: .completed, detail: "", outcome: .lost)
        }
    }

    /// The index of the open run with `token`, or `nil`.
    private func index(of token: String) -> Int? {
        runs.firstIndex { $0.token == token }
    }

    /// The index of the pending elicitation with `id`, or `nil`.
    private func elicitationIndex(of id: ULID) -> Int? {
        elicitations.firstIndex { $0.id == id }
    }
}
