import Foundation
import ULID

/// The background runs of one session, and the questions that those runs ask.
///
/// Each session has its own run plane, and a fork gets a new one. The run
/// plane holds events and outcomes, never bulk output. A completion token
/// names a run: it is a ULID string, and it is also the `correlationID` of
/// each event of the run.
actor RunPlane {
    /// What ``start(tool:op:kind:completionToken:canceler:body:)`` did.
    enum StartResult: Sendable, Equatable {
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

    /// Whether a ``sweep()`` runs now. A second sweep at the same time
    /// returns nothing.
    private var isSweeping = false

    /// Gets the terminal event of each run that settles by itself. Weak,
    /// because the observer is the session that owns this run plane.
    private weak var settlementObserver: (any BackgroundRunSettlementObserver)?

    /// Makes an empty run plane.
    init() {}

    /// A new completion token: a ULID string.
    static func makeCompletionToken() -> String {
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
    func start(
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
        let work = Task { [weak self] in
            let terminal = await body()
            await self?.settleByItself(completionToken, with: terminal)
        }
        let cooperative: @Sendable () async -> OperationOutcome = {
            work.cancel()
            return .cancelled
        }
        runs.append(Run(token: completionToken, tool: tool, op: op, kind: kind, canceler: canceler ?? cooperative))
        return .started
    }

    /// Installs the observer that gets the terminal event of each run that
    /// settles by itself from now on.
    ///
    /// - Parameter settlementObserver: The observer.
    func attach(settlementObserver: any BackgroundRunSettlementObserver) {
        self.settlementObserver = settlementObserver
    }

    /// Records the latest progress detail of a run. An unknown token does
    /// nothing.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - detail: The progress detail.
    func updateProgress(completionToken: String, detail: String) {
        guard let index = index(of: completionToken) else { return }
        runs[index].latestProgressDetail = detail
    }

    // Tool hosting 4 (^ebtprdg) makes this public for the session pump.
    // periphery:ignore
    /// The completion tokens of the settled runs.
    ///
    /// - Returns: The tokens.
    func settledRunTokens() -> Set<String> {
        Set(settled.keys)
    }

    /// Each open run, in start order.
    ///
    /// - Returns: The runs, with no output.
    func backgroundRuns() -> [BackgroundRun] {
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
    func wait(completionToken: String, seconds: Double?) async -> WaitOutcome {
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
        let elicitation = Elicitation(id: request.elicitationId, mode: request.mode)
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
    func respond(elicitationId: ULID, _ response: ElicitationResponse) -> ElicitationAnswerDelivery {
        guard let index = elicitationIndex(of: elicitationId), elicitations[index].accepted == nil else {
            return .noPendingElicitation
        }
        if elicitations[index].mode == .url && response.action == .accept {
            elicitations[index].accepted = response
            return .acceptedAwaitingCompletion
        }
        elicitations.remove(at: index).answer.fulfill(response)
        return .delivered
    }

    /// Tells that the flow of an accepted URL elicitation ended, and resumes
    /// the run. An unknown id, or one with no accept, does nothing.
    ///
    /// - Parameter elicitationId: The id of the elicitation.
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    func complete(elicitationId: ULID) -> ElicitationCompletionDelivery {
        guard let index = elicitationIndex(of: elicitationId), let accepted = elicitations[index].accepted else {
            return .noPendingElicitation
        }
        elicitations.remove(at: index).answer.fulfill(accepted)
        return .completed
    }

    // MARK: - The sweep

    /// The sweep at the end of a session: cancels each open run in start
    /// order, gives one terminal event for each, then answers each pending
    /// elicitation with ``ElicitationResponse/cancel``.
    ///
    /// - Returns: One terminal event for each run that was open when the
    ///   sweep started. A sweep while another sweep runs returns nothing.
    func sweep() async -> [OperationEvent] {
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
            elicitation.answer.fulfill(.cancel)
        }
        elicitations.removeAll()
        return terminals
    }

    // MARK: - Helpers

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

    /// Moves an open run to the settled runs, and resumes each wait for it.
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
        for waiter in run.waiters.values {
            waiter.resume(with: .settled(terminal))
        }
        return true
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
