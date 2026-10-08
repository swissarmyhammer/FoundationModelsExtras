import Foundation
import FoundationModels

/// A decorator that runs each call of the tool in the background, unless the
/// tool gives a synchronous mount for that call.
///
/// A background call posts one progress event, starts the run on the run
/// plane, and waits for the run up to its settle period. A run that ends in
/// that time answers with its own result, the same as a synchronous call: the
/// output of the tool, or the error that the tool threw. A run that continues
/// answers with a ``PendingRunEnvelope``, and settles later with one terminal
/// event: at its end, at a cancel, or at the timeout.
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
    /// The span covers only the start and the wait. A run that continues
    /// settles later on the run plane.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool, or the rendered envelope.
    /// - Throws: The error of a run that ended inside the settle period.
    func callInBackground(arguments: Arguments) async throws -> String {
        try await ToolCallSpan.withSpan(
            tracer: site.tracer, toolName: wrapped.name, sessionID: site.sessionID, runKind: .background
        ) { call in
            let rendered = try await start(arguments: arguments)
            ToolCallSpan.record(outcome: .succeeded, on: call)
            return rendered
        }
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
        let remaining = Self.seconds(of: outerEnd - ContinuousClock.now)
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
    /// result two times.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool, or the rendered pending envelope.
    /// - Throws: The error of a run that ended inside the settle period.
    private func start(arguments: Arguments) async throws -> String {
        let grace = grace
        let deadline = ContinuousClock.now.advanced(by: .seconds(grace))
        let run = ToolRun(
            wrapped: wrapped, arguments: arguments, site: site, mountTimeout: timeout, inlineSettleDeadline: deadline)
        let token = run.context.completionToken
        let pending = PendingRunEnvelope(
            completionToken: token, next: declared?.collectInstruction(forCompletionToken: token))
        let result = Promise<Result<String, any Error>>()
        await run.open()
        await run.context.progress(pending.rendered)
        await site.runPlane.start(
            tool: run.context.tool,
            op: run.context.op,
            kind: declared?.runKind ?? .swiftTask,
            completionToken: token,
            canceler: canceler(of: run)
        ) {
            // The run goes on beside the model call that started it, not in it.
            await ModelCallMark.withBackgroundRunMark {
                let settlement = await run.execute(arguments: arguments)
                result.fulfill(settlement.result)
                return settlement.terminal
            }
        }
        guard grace > 0,
            case .settled(let terminal) = await site.runPlane.wait(completionToken: token, seconds: grace)
        else {
            return pending.rendered
        }
        await (site.sink as? any StagedEventWithdrawing)?.withdrawStagedEvents(correlationID: token)
        // The body gives its result before it returns the terminal event, so
        // a run that the body settled has its result here. A run that the run
        // plane settled while the body still runs (a sweep, or a stop of a
        // process) has none, and the call must not wait for a body that can
        // ignore the cancel. That call answers from the terminal event.
        guard let ownResult = result.fulfilledValue else {
            return terminal.detail
        }
        return try ownResult.get()
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
