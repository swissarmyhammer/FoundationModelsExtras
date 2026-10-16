import Foundation
import FoundationModels

/// A decorator that runs each call of the tool in the background, unless the
/// tool gives a synchronous mount for that call.
///
/// A background call starts the run on the run plane, posts one progress
/// event before the body of the run starts its work, and waits for the run up
/// to its settle period. A call whose run the run plane refuses posts nothing,
/// and fails with ``DuplicateRunTokenError``. A run that ends in
/// that time answers with its own result, the same as a synchronous call: the
/// output of the tool, or the error that the tool threw. A cancel of only that
/// run is not a cancel of the call: the call answers with a text that tells
/// the model that the run was cancelled. A run that continues answers with a
/// ``PendingRunEnvelope``, and settles later with one terminal event: at its
/// end, at a cancel, or at the timeout.
struct BackgroundToolRunner<
    Arguments: ConvertibleFromGeneratedContent & Sendable
>: MountRunner, SubmissionBoundaryTool, ToolDecorator {
    static var defaultMode: ToolMount.Mode { .background }

    /// How much of the settle period of an outer run an inner call leaves to
    /// the outer run, in seconds.
    ///
    /// A script runner waits for its own settle period, and its script makes
    /// inner calls. An inner call that waited to the end of the outer period
    /// would leave no time for the script to use the result, and the outer
    /// call would answer with a pending envelope that holds a pending
    /// envelope. So an inner call stops its wait this long before the end of
    /// the outer period.
    static var innerCallSettleReserve: TimeInterval { 1 }

    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, String>

    /// Where the tool runs.
    let site: MountSite

    /// The timeout with no progress, or `nil` for none. A timeout that the
    /// tool gives for one call wins.
    let timeout: TimeInterval?

    /// Starts one call in the background, and returns its result when the
    /// run ends inside the settle period, or else its envelope.
    ///
    /// The span and the duration of the call cover the start of the run and
    /// the wait up to the end of the settle period. A run that continues
    /// settles later on the run plane, outside the span.
    ///
    /// Each call records exactly one count and one duration, also when it
    /// throws. A run that settled inside the settle period records the
    /// outcome of its terminal event, also when the run plane settled it
    /// while its body still runs. A call that answers with the pending
    /// envelope records ``ToolCallSpan/outcomeOfStartedRun``. The span gets
    /// `tool.settled_inline`. A timeout is not an error: it gives the span no
    /// error status, and the call throws it after the span ends.
    ///
    /// A call stops only for its own cancel. A run that a cancel of only that
    /// run (``RunPlane/cancel(completionToken:)``) ends inside the settle
    /// period answers with ``cancelledRunText(completionToken:tool:)``, and
    /// the model reads it. The span still records the outcome `cancelled`.
    /// When the task of this call is cancelled, the call throws the
    /// `CancellationError` of the run.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool, the text of a run that a cancel of
    ///   only that run ended, or the rendered envelope.
    /// - Throws: The error of a run that ended inside the settle period. A
    ///   `CancellationError` only when the task of this call is cancelled.
    func callInBackground(arguments: Arguments) async throws -> String {
        let result = try await ToolCallSpan.withSpan(
            tracer: site.tracer, toolName: wrapped.name, sessionID: site.sessionID, runKind: .background
        ) { call in
            let answer = await start(arguments: arguments)
            ToolCallSpan.record(settledTerminal: answer.settledTerminal, on: call)
            return try ToolCallSpan.spanResult(of: answer.result)
        }
        return try result.get()
    }

    /// The answer of one background call to the model, and how its run
    /// stood at the end of the settle period.
    private struct Answer {
        /// The output of the tool, the text of a run that a cancel of only
        /// that run ended, or the rendered pending envelope, or the error of
        /// a run that ended inside the settle period.
        let result: Result<String, any Error>

        /// The terminal event of a run that settled inside the settle
        /// period, or `nil` when the call answers with the pending envelope.
        let settledTerminal: OperationEvent?
    }

    /// The tool as a ``BackgroundTool``, or `nil`.
    private var declared: (any BackgroundTool)? {
        wrapped as? any BackgroundTool
    }

    /// The settle period of this call, in seconds.
    ///
    /// It is the grace of the tool, or the configured period of the site for
    /// a tool that states none. Inside the settle period of an outer run, it
    /// ends ``innerCallSettleReserve`` before the end of that period. Outside
    /// it, the outer run already answered, and the call waits for its full
    /// period.
    private var grace: TimeInterval {
        let stated = InlineSettle.$configuredGrace.withValue(site.inlineSettleGrace) {
            declared?.inlineSettleGrace ?? site.inlineSettleGrace
        }
        let own = max(0, stated)
        guard let outerEnd = site.inlineSettleDeadline else { return own }
        let remaining = Self.seconds(of: outerEnd - site.runPlane.clock.now)
        guard remaining > 0 else { return own }
        return min(own, max(0, remaining - Self.innerCallSettleReserve))
    }

    /// Opens the run, starts its body on the run plane, and waits for it up to
    /// the settle period.
    ///
    /// The model pays one round trip for each run that it collects, and a
    /// short run costs less than that trip. So the wait gives the result in
    /// the same output. The wait never cancels the run: a run that continues
    /// settles behind the pending envelope. The sink takes back the staged
    /// events of a run that answers here, so the model does not read the
    /// result two times. The sink does not take back a display event of the
    /// run: the model never reads it, and the client already shows it. See
    /// ``StagedEventWithdrawing``.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool, the error of a run that ended
    ///   inside the settle period, the text of a run that a cancel of only
    ///   that run ended there, or the rendered pending envelope, with the
    ///   terminal event of a run that settled.
    private func start(arguments: Arguments) async -> Answer {
        let grace = grace
        let deadline = site.runPlane.clock.now.advanced(by: .seconds(grace))
        // A background call is a run of its own, so its questions stop only
        // this run.
        let run = makeRun(arguments: arguments, on: site.held(by: nil, settlingBy: deadline))
        let token = run.context.completionToken
        let pending = PendingRunEnvelope(
            completionToken: token, next: declared?.collectInstruction(forCompletionToken: token))
        let result = Promise<Result<String, any Error>>()
        // The body waits until the call posted its open record and its
        // envelope, thus each event of the run comes after them.
        let posted = Promise<Void>()
        let started = await site.runPlane.start(
            tool: run.context.tool,
            op: run.context.op,
            kind: declared?.runKind ?? .swiftTask,
            completionToken: token,
            canceler: canceler(of: run),
            tracer: site.tracer
        ) {
            await posted.value
            // The run goes on beside the model call that started it, not in it.
            return await ModelCallMark.withBackgroundRunMark {
                let settlement = await run.execute(arguments: arguments)
                result.fulfill(settlement.result)
                return settlement.terminal
            }
        }
        guard started == .started else {
            return Self.refusedAnswer(completionToken: token, tool: run.context.tool)
        }
        // The body must not wait for ever, thus the gate opens on each path
        // out of this call, and at a cancel of its task.
        defer { posted.fulfill(()) }
        await withTaskCancellationHandler {
            await run.open()
            await run.post(pendingEnvelope: pending.rendered)
        } onCancel: {
            posted.fulfill(())
        }
        posted.fulfill(())
        guard grace > 0,
            case .settled(let terminal) = await site.runPlane.wait(completionToken: token, seconds: grace)
        else {
            return Answer(result: .success(pending.rendered), settledTerminal: nil)
        }
        await (site.sink as? any StagedEventWithdrawing)?.withdrawStagedEvents(correlationID: token)
        // The body gives its result before it returns the terminal event, so
        // a run that the body settled has its result here. A run that the run
        // plane settled while the body still runs (a sweep, or a stop of a
        // process) has none, and the call must not wait for a body that can
        // ignore the cancel. That call answers from the terminal event.
        let settled = result.fulfilledValue ?? .success(terminal.detail)
        return Answer(
            result: Self.modelResult(of: settled, completionToken: token, tool: run.context.tool),
            settledTerminal: terminal)
    }

    /// The answer of a call whose run the run plane refused, because a
    /// different run has the same completion token. The call posted nothing
    /// under that token, thus the other run keeps its events. It writes one
    /// error log line, and fails with ``DuplicateRunTokenError``.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token that the run plane refused.
    ///   - tool: The name of the tool of the call.
    /// - Returns: The failure, with no terminal event.
    private static func refusedAnswer(completionToken: String, tool: String) -> Answer {
        let error = DuplicateRunTokenError(completionToken: completionToken, tool: tool)
        ExtrasTelemetry.makeLogger().error("\(error.description)")
        return Answer(result: .failure(error), settledTerminal: nil)
    }

    /// The text that the model reads for the run `completionToken` of `tool`
    /// when a cancel of only that run ended it inside the settle period.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - tool: The name of the tool of the run.
    /// - Returns: The text.
    static func cancelledRunText(completionToken: String, tool: String) -> String {
        "The run \(completionToken) of \(tool) was cancelled before it ended, so it gives no result."
    }

    /// The result that the model reads for a run that settled inside the
    /// settle period.
    ///
    /// A run that ended with `CancellationError` while the task of this call
    /// is not cancelled was cancelled alone. Its result is
    /// ``cancelledRunText(completionToken:tool:)``, so the answer of the
    /// model goes on. Each other result stays as it is.
    ///
    /// - Parameters:
    ///   - settled: The result of the run.
    ///   - completionToken: The completion token of the run.
    ///   - tool: The name of the tool of the run.
    /// - Returns: The result for the model.
    private static func modelResult(
        of settled: Result<String, any Error>, completionToken: String, tool: String
    ) -> Result<String, any Error> {
        guard case .failure(let error) = settled, error is CancellationError, !Task.isCancelled else {
            return settled
        }
        return .success(cancelledRunText(completionToken: completionToken, tool: tool))
    }

    /// `duration` in seconds.
    private static func seconds(of duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// The canceler of the tool, or `nil` for the cooperative canceler of the
    /// run plane. The canceler of a ``RunKind/process`` tool is certain, so
    /// its outcome is also the outcome of the run.
    private func canceler(of run: ToolRun<Arguments>) -> (@Sendable () async -> OperationOutcome)? {
        guard let tool = declared, let supplied = tool.canceler(forCompletionToken: run.context.completionToken) else {
            return nil
        }
        guard tool.runKind == .process else {
            return supplied
        }
        return { await run.stop(using: supplied) }
    }
}

/// The error of a background call whose run did not start, because the run
/// plane already has a run with the same completion token. The run plane
/// makes each token new, thus this error shows a defect.
struct DuplicateRunTokenError: Error, CustomStringConvertible {
    /// The completion token that the run plane refused.
    let completionToken: String

    /// The name of the tool of the call.
    let tool: String

    /// The text that the model and the log read.
    var description: String {
        "The run of \(tool) did not start, because a different run already has the completion token \(completionToken)."
    }
}
