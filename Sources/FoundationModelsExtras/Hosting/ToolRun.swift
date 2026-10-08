import Foundation
import FoundationModels
import Synchronization
import ULID

/// One call of a `String` tool, from its open record to its terminal event.
/// ``RunToCompletionRunner`` and ``BackgroundToolRunner`` both use it.
struct ToolRun<Arguments: ConvertibleFromGeneratedContent & Sendable>: Sendable {
    /// The called tool.
    private let wrapped: any Tool<Arguments, String>

    /// The sink of the session: it gets the records and the report.
    private let sink: any OperationEventSink

    /// The context that the body runs in. Its completion token names the run.
    let context: ToolContext

    /// The one route of the events of the run.
    private let funnel: RunEventFunnel

    /// The cancel flag, the records and the stop of the call.
    private let state: ToolCallState

    /// The timeout of the call, or `nil` for none.
    private let timeoutSeconds: TimeInterval?

    /// The open record of the call.
    private let openRecord: ToolInvocationRecord

    /// Prepares one call. A timeout from the tool for this call wins over
    /// `mountTimeout`.
    ///
    /// - Parameters:
    ///   - wrapped: The called tool.
    ///   - arguments: The arguments of the call.
    ///   - site: The mount site of the call.
    ///   - mountTimeout: The timeout of the mount, or `nil` for none.
    ///   - inlineSettleDeadline: The end of the settle period that the inner
    ///     calls of the run must keep, or `nil` for none.
    init(
        wrapped: any Tool<Arguments, String>,
        arguments: Arguments,
        site: MountSite,
        mountTimeout: TimeInterval?,
        inlineSettleDeadline: ContinuousClock.Instant?
    ) {
        let token = RunPlane.makeCompletionToken()
        let funnel = RunEventFunnel(upstream: site.sink, runPlane: site.runPlane, completionToken: token)
        let state = ToolCallState()
        self.wrapped = wrapped
        self.sink = site.sink
        self.funnel = funnel
        self.state = state
        self.context = ToolContext(
            calling: wrapped, on: site, sink: funnel, completionToken: token, state: state,
            inlineSettleDeadline: inlineSettleDeadline)
        self.timeoutSeconds = Self.timeout(of: wrapped, for: arguments) ?? mountTimeout
        self.openRecord = ToolInvocationRecord(opening: context)
    }

    /// The timeout that `wrapped` gives for `arguments`, or `nil`.
    private static func timeout(of wrapped: any Tool<Arguments, String>, for arguments: Arguments) -> TimeInterval? {
        guard let declared = ToolMounting.backgroundDeclaration(of: wrapped, for: arguments) else {
            return nil
        }
        return declared.tool.timeout(from: declared.content)
    }

    /// Posts the open record of the call.
    func open() async {
        await sink.post(invocation: openRecord)
    }

    /// Runs the canceler of the tool one time, and reports its outcome. The
    /// terminal event of the run gets this outcome, whatever the body returns.
    ///
    /// The canceler runs in a task that the call keeps, so the settlement
    /// can wait for the outcome of a stop that started before the body
    /// returned. A second call waits for the first stop.
    ///
    /// - Parameter canceler: The canceler of the tool.
    /// - Returns: The outcome that the canceler reports.
    func stop(using canceler: @escaping @Sendable () async -> OperationOutcome) async -> OperationOutcome {
        await state.stop(using: canceler).value
    }

    /// Runs the body in the context, settles the run with one terminal event,
    /// posts the close record, and then posts the report of the call when
    /// the call attached a record.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: How the run ended.
    func execute(arguments: Arguments) async -> RunSettlement {
        let settlement = await ToolContext.$current.withValue(context) {
            await settle(arguments: arguments)
        }
        let closeRecord = openRecord.closed(at: Date())
        await sink.post(invocation: closeRecord)
        await sink.postToolCallReport(closing: closeRecord, attachments: settlement.attachments)
        return settlement
    }

    /// Calls the tool, with the timeout, and settles the run.
    private func settle(arguments: Arguments) async -> RunSettlement {
        // Made in the context binding, so the call reads the context.
        let call = Task { try await wrapped.call(arguments: arguments) }
        let result = await withTaskCancellationHandler {
            await resultOrTimeout(of: call)
        } onCancel: {
            state.requestCancel()
            call.cancel()
        }
        // A record that the tool attaches after this point belongs to no
        // settlement, and is dropped.
        let attachments = state.drainAttachments()
        let (outcome, detail) = Self.outcomeAndDetail(of: result, stoppedAs: await state.stopOutcome)
        let terminal = OperationEvent(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            kind: .completed,
            detail: detail,
            outcome: outcome
        )
        await funnel.settleRun(with: terminal)
        return RunSettlement(result: result, terminal: terminal, attachments: attachments)
    }

    /// The result of `call`, or a timeout failure when a full timeout window
    /// passes with no progress and no pending elicitation.
    ///
    /// At a timeout, this function cancels the call and returns at once. It
    /// does not wait for the tool to stop: a tool that ignores the cancel
    /// would then hold the call for ever, and the timeout is there to end
    /// the call.
    ///
    /// - Parameter call: The task of the call.
    /// - Returns: The result of the call, or ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
    private func resultOrTimeout(of call: Task<String, any Error>) async -> Result<String, any Error> {
        guard let timeoutSeconds else {
            return await call.result
        }
        let first = Promise<Result<String, any Error>?>()
        Task { first.fulfill(await call.result) }
        let watch = Task {
            if await funnel.waitForTimeout(seconds: timeoutSeconds) {
                first.fulfill(nil)
            }
        }
        let result = await first.value
        watch.cancel()
        guard let result else {
            state.requestCancel()
            call.cancel()
            return .failure(ToolMountError.timedOut(tool: context.tool, timeoutSeconds: timeoutSeconds))
        }
        return result
    }

    /// The outcome and the detail of the terminal event. The outcome of a
    /// stop wins over the outcome of the result; the detail stays.
    private static func outcomeAndDetail(
        of result: Result<String, any Error>,
        stoppedAs stop: OperationOutcome?
    ) -> (OperationOutcome, String) {
        switch result {
        case .success(let output):
            return (stop ?? .succeeded, output)
        case .failure(let error):
            return (stop ?? outcome(of: error), String(describing: error))
        }
    }

    /// The outcome of a call that threw `error`.
    private static func outcome(of error: any Error) -> OperationOutcome {
        switch error {
        case is CancellationError: .cancelled
        case ToolMountError.timedOut: .timedOut
        case is any LostRunError: .lost
        default: .failed
        }
    }
}

/// How the body of one run ended.
struct RunSettlement: Sendable {
    /// The output of the tool, or the error that ended the call.
    let result: Result<String, any Error>

    /// The terminal event of the run, already sent to the funnel.
    let terminal: OperationEvent

    /// The records that the tool attached, in call order.
    let attachments: [ToolCallAttachment]
}

/// The state that one call shares with the task of the tool: the cancel flag,
/// the attached records, and the stop of a process canceler.
final class ToolCallState: Sendable {
    /// Whether a cancel was asked. It is never cleared.
    private let cancelRequested = Atomic(false)

    /// The attached records, in call order.
    private let attachments = Mutex<[ToolCallAttachment]>([])

    /// The first stop, or `nil` when no stop started.
    private let stopTask = Mutex<Task<OperationOutcome, Never>?>(nil)

    /// Whether a cancel was asked.
    var isCancelRequested: Bool {
        cancelRequested.load(ordering: .acquiring)
    }

    /// Records that a cancel was asked.
    func requestCancel() {
        cancelRequested.store(true, ordering: .releasing)
    }

    /// Appends `attachment` after each earlier record.
    ///
    /// - Parameter attachment: The record.
    func attach(_ attachment: ToolCallAttachment) {
        attachments.withLock { $0.append(attachment) }
    }

    /// Removes and returns each record, in call order.
    ///
    /// - Returns: The records.
    func drainAttachments() -> [ToolCallAttachment] {
        attachments.withLock { records in
            defer { records.removeAll() }
            return records
        }
    }

    /// The task of the first stop. The first call starts it with `canceler`.
    ///
    /// - Parameter canceler: The canceler of the tool.
    /// - Returns: The task of the stop.
    func stop(using canceler: @escaping @Sendable () async -> OperationOutcome) -> Task<OperationOutcome, Never> {
        stopTask.withLock { stop in
            if let stop {
                return stop
            }
            let started = Task { await canceler() }
            stop = started
            return started
        }
    }

    /// The outcome of the stop, or `nil` when no stop started.
    var stopOutcome: OperationOutcome? {
        get async {
            await stopTask.withLock { $0 }?.value
        }
    }
}

/// The one route of the events of one run. It lets one `.completed` event
/// through, keeps the state of the timeout, and delivers the events upstream
/// in order.
actor RunEventFunnel: OperationEventSink {
    /// The sink of the session.
    private let upstream: any OperationEventSink

    /// The run plane of the session.
    private let runPlane: RunPlane

    /// The completion token of the run.
    private let completionToken: String

    /// Whether an event went upstream.
    private var hasDeliveredAnyEvent = false

    /// Whether the terminal event went upstream.
    private var hasDeliveredTerminal = false

    /// Increases with each progress event, each message and each answered
    /// elicitation.
    private var resetCount = 0

    /// The elicitations of this run that have no answer yet.
    private var pendingElicitationIds: Set<ULID> = []

    /// The upstream deliveries, in order.
    private var deliveries = SerialAsyncChain()

    /// Makes the funnel of one run.
    ///
    /// - Parameters:
    ///   - upstream: The sink of the session.
    ///   - runPlane: The run plane of the session.
    ///   - completionToken: The completion token of the run.
    init(upstream: any OperationEventSink, runPlane: RunPlane, completionToken: String) {
        self.upstream = upstream
        self.runPlane = runPlane
        self.completionToken = completionToken
    }

    /// Records the timeout state of `event`, then sends it upstream. A second
    /// terminal event is dropped, and so is a message after the terminal
    /// event.
    ///
    /// - Parameter event: The event.
    func post(event: OperationEvent) async {
        switch event.kind {
        case .completed:
            guard !hasDeliveredTerminal else { return }
            hasDeliveredTerminal = true
        case .progress:
            resetCount += 1
        case .message:
            guard !hasDeliveredTerminal else { return }
            resetCount += 1
        case .elicitation:
            if let elicitationId = event.elicitation?.elicitationId {
                pendingElicitationIds.insert(elicitationId)
            }
        }
        hasDeliveredAnyEvent = true
        let delivery = enqueue(event)
        if event.kind == .progress {
            await runPlane.updateProgress(completionToken: completionToken, detail: event.detail)
        }
        await delivery.value
    }

    /// Sends `terminal` upstream when no terminal event went yet, and the run
    /// posted an event or did not succeed. A silent success posts nothing.
    ///
    /// - Parameter terminal: The terminal event of the run.
    func settleRun(with terminal: OperationEvent) async {
        guard !hasDeliveredTerminal, hasDeliveredAnyEvent || terminal.outcome != .succeeded else { return }
        hasDeliveredTerminal = true
        await enqueue(terminal).value
    }

    /// Waits until a full window of `seconds` passes with no progress and no
    /// pending elicitation.
    ///
    /// - Parameter seconds: The timeout.
    /// - Returns: `true` at the timeout, `false` when the wait was cancelled.
    func waitForTimeout(seconds: TimeInterval) async -> Bool {
        let window = RunPlane.boundedNanoseconds(clamping: seconds)
        while true {
            let before = await refreshedResetCount()
            do {
                try await Task.sleep(nanoseconds: window)
            } catch {
                return false
            }
            // Progress in the window, or a pending elicitation, shows that the
            // call is alive: wait one more full window.
            if await refreshedResetCount() == before, pendingElicitationIds.isEmpty {
                return true
            }
        }
    }

    /// The reset count, after it counts the elicitations that got an answer.
    private func refreshedResetCount() async -> Int {
        guard !pendingElicitationIds.isEmpty else { return resetCount }
        let answered = pendingElicitationIds.subtracting(await runPlane.pendingElicitationIds())
        if !answered.isEmpty {
            resetCount += 1
            pendingElicitationIds.subtract(answered)
        }
        return resetCount
    }

    /// Adds the upstream delivery of `event` behind the earlier deliveries.
    private func enqueue(_ event: OperationEvent) -> Task<Void, Never> {
        let upstream = upstream
        return deliveries.enqueue { await upstream.post(event: event) }
    }
}
