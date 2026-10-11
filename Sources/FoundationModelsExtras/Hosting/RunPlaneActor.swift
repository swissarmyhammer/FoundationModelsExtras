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
    /// What ``start(tool:op:kind:completionToken:canceler:body:)`` did.
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

        /// The mode of the request.
        let mode: ElicitationMode

        /// The accept of a URL elicitation that waits for its completion.
        var accepted: ElicitationResponse?

        /// Gets the answer that resumes the run.
        let answer = Promise<ElicitationResponse>()

        /// The queue ticket of the elicitation, from the time it became
        /// pending. Its exit from the list completes it.
        let ticket: QueueTicket
    }

    /// Nanoseconds in one second.
    private static let nanosecondsPerSecond: Double = 1_000_000_000

    /// The open runs, in start order.
    private var runs: [Run] = []

    /// The terminal event of each settled run, by completion token. The run
    /// plane keeps each one for the life of the session, so a late `wait` or
    /// `cancel` gets the terminal event, not `unknownToken`.
    private var settled: [String: OperationEvent] = [:]

    /// The pending elicitations, in the order they came.
    private var elicitations: [Elicitation] = []

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

    /// Makes an empty run plane.
    public init() {}

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
        body: @escaping @Sendable () async -> OperationEvent
    ) -> StartResult {
        guard index(of: completionToken) == nil, settled[completionToken] == nil else {
            return .duplicateToken
        }
        var ticket = runTelemetry.enqueued()
        runTelemetry.started(&ticket)
        let work = Task { [weak self] in
            let terminal = await Self.runTraced(body, tool: tool, op: op, kind: kind, completionToken: completionToken)
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
        runs.map { run in
            BackgroundRun(
                completionToken: run.token,
                tool: run.tool,
                op: run.op,
                kind: run.kind,
                latestProgressDetail: run.latestProgressDetail
            )
        }
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

    /// Runs the canceler of a run and reports its outcome as is. The run
    /// stays open until it settles.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: ``CancelOutcome/reported(_:)``, or
    ///   ``CancelOutcome/alreadySettled(_:)`` when the run settled first, or
    ///   ``CancelOutcome/unknownToken``.
    func cancel(completionToken: String) async -> CancelOutcome {
        if let terminal = settled[completionToken] {
            return .alreadySettled(terminal)
        }
        guard let index = index(of: completionToken) else {
            return .unknownToken
        }
        return .reported(await runs[index].canceler())
    }

    // MARK: - Pending elicitations

    /// Suspends the calling run until its elicitation gets an answer. An
    /// accepted URL elicitation also waits for ``complete(elicitationId:)``.
    ///
    /// The elicitation is pending before `posting` runs. A duplicate
    /// `elicitationId` gets ``ElicitationResponse/cancel`` at once, and
    /// `posting` does not run.
    ///
    /// - Parameters:
    ///   - request: The request. Its `elicitationId` names the elicitation.
    ///   - posting: Sends the request to the host.
    /// - Returns: The answer of the user.
    func awaitAnswer(
        to request: ElicitationRequest,
        posting: @escaping @Sendable () async -> Void = {}
    ) async -> ElicitationResponse {
        guard elicitationIndex(of: request.elicitationId) == nil else {
            return .cancel
        }
        let elicitation = Elicitation(
            id: request.elicitationId, mode: request.mode, ticket: elicitationTelemetry.enqueued())
        elicitations.append(elicitation)
        Task { await posting() }
        return await elicitation.answer.value
    }

    /// The ids of the pending elicitations, in the order they came.
    ///
    /// - Returns: The ids.
    func pendingElicitationIds() -> [ULID] {
        elicitations.map(\.id)
    }

    /// Gives the answer of the user to a pending elicitation.
    ///
    /// A URL accept keeps the elicitation open until
    /// ``complete(elicitationId:)``. Each other answer resumes the run. An
    /// unknown or answered id does nothing.
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
    /// - Parameter elicitationId: The id of the elicitation.
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    public func complete(elicitationId: ULID) -> ElicitationCompletionDelivery {
        guard let index = elicitationIndex(of: elicitationId), let accepted = elicitations[index].accepted else {
            return .noPendingElicitation
        }
        finish(elicitations.remove(at: index), with: accepted)
        return .completed
    }

    // MARK: - The sweep

    /// The sweep at the end of a session: cancels each open run in start
    /// order, gives one terminal event for each, then answers each pending
    /// elicitation with ``ElicitationResponse/cancel``.
    ///
    /// - Returns: One terminal event for each run that was open when the
    ///   sweep started. A sweep while another sweep runs returns nothing.
    public func sweep() async -> [OperationEvent] {
        guard !isSweeping else { return [] }
        isSweeping = true
        defer { isSweeping = false }
        var terminals: [OperationEvent] = []
        for token in runs.map(\.token) {
            guard let index = index(of: token) else { continue }
            let run = runs[index]
            let outcome = await run.canceler()
            // The canceler suspends this actor, so the run can settle by
            // itself in that time. Its own terminal event is then the one
            // terminal event of the run.
            if let own = settled[token] {
                terminals.append(own)
                continue
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
            terminals.append(swept)
        }
        for elicitation in elicitations {
            finish(elicitation, with: .cancel)
        }
        elicitations.removeAll()
        return terminals
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
        let deadline = seconds.map { seconds in
            Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.boundedNanoseconds(clamping: seconds))
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
    /// and its "enter" record shows the hung run. The span uses
    /// `InstrumentationSystem.tracer` at call time, thus the task-local
    /// tracer and the span of the caller, which the task of the body
    /// inherits.
    ///
    /// - Parameters:
    ///   - body: The work of the run.
    ///   - tool: The name of the tool that owns the run.
    ///   - op: The op of the run, for the terminal event of the fallback only.
    ///   - kind: The kind of work of the run.
    ///   - completionToken: The completion token of the run.
    /// - Returns: The terminal event of `body`.
    private static func runTraced(
        _ body: @Sendable () async -> OperationEvent,
        tool: String,
        op: String,
        kind: RunKind,
        completionToken: String
    ) async -> OperationEvent {
        let logger = ExtrasTelemetry.makeLogger()
        do {
            return try await TracedCall.run(
                ExtrasTelemetry.SpanName.run,
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
