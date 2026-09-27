import Foundation
import FoundationModels

/// A decorator that runs each call of the tool in the background, unless the
/// tool gives a synchronous mount for that call. A background call
/// posts one progress event, starts the run on the run plane, and returns a
/// ``PendingRunEnvelope``. The run settles later with one terminal event: at
/// its end, at a cancel, or at the timeout.
///
/// A tool that declares ``BackgroundTool/inlineSettleGrace`` waits that long
/// before it answers. A run that settles in that time answers with its result
/// in the same envelope.
struct BackgroundToolRunner<
    Arguments: ConvertibleFromGeneratedContent & Sendable
>: Tool, SubmissionBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, String>

    /// Where the tool runs.
    private let site: MountSite

    /// The timeout with no progress, or `nil` for none. A timeout that the
    /// tool gives for one call wins.
    let timeout: TimeInterval?

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Wraps `wrapped`.
    ///
    /// - Parameters:
    ///   - wrapped: The tool.
    ///   - site: Where the tool runs.
    ///   - timeout: The timeout with no progress, or `nil` for none.
    init(wrapping wrapped: any Tool<Arguments, String>, site: MountSite, timeout: TimeInterval?) {
        self.wrapped = wrapped
        self.site = site
        self.timeout = timeout
    }

    /// Runs one call with the mount that the tool gives for `arguments`, or
    /// else in the background. See ``ToolMounting/call(_:arguments:site:mount:)``.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The rendered envelope, or the output of a synchronous call.
    func call(arguments: Arguments) async throws -> String {
        try await ToolMounting.call(
            wrapped, arguments: arguments, site: site, mount: ToolMount(mode: .background, timeout: timeout))
    }

    /// Starts one call in the background and returns its envelope.
    ///
    /// The span covers only the start. The run settles later on the run
    /// plane.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The rendered envelope.
    func callInBackground(arguments: Arguments) async throws -> String {
        try await ToolCallSpan.withSpan(
            tracer: site.tracer, toolName: wrapped.name, sessionID: site.sessionID, runKind: .background
        ) { span in
            let rendered = await start(arguments: arguments)
            ToolCallSpan.record(outcome: .succeeded, on: span)
            return rendered
        }
    }

    /// The tool as a ``BackgroundTool``, or `nil`.
    private var declared: (any BackgroundTool)? {
        wrapped as? any BackgroundTool
    }

    /// Opens the run, starts its body on the run plane, and returns the
    /// envelope that the model gets in place of the result.
    private func start(arguments: Arguments) async -> String {
        let run = ToolRun(wrapped: wrapped, arguments: arguments, site: site, mountTimeout: timeout)
        let token = run.context.completionToken
        let pending = PendingRunEnvelope(
            completionToken: token, next: declared?.collectInstruction(forCompletionToken: token))
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
                await run.execute(arguments: arguments).terminal
            }
        }
        return await settledEnvelope(of: token)?.rendered ?? pending.rendered
    }

    /// Waits up to the grace of the tool for the run of `token`, and makes
    /// the envelope that holds its result.
    ///
    /// The model pays one round trip for each run that it collects, and a
    /// short run costs less than that trip. So a short wait here gives the
    /// result in the same output, and the model does not call `wait`. The
    /// wait never cancels the run: a run that continues settles behind the
    /// pending envelope. The sink takes back the staged events of a run that
    /// answers here, so the model does not read the result two times.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The settled envelope, or `nil` when the run continues.
    private func settledEnvelope(of token: String) async -> PendingRunEnvelope? {
        guard
            let tool = declared,
            let grace = tool.inlineSettleGrace, grace > 0,
            case .settled(let terminal) = await site.runPlane.wait(completionToken: token, seconds: grace),
            let outcome = terminal.outcome
        else {
            return nil
        }
        await (site.sink as? any StagedEventWithdrawing)?.withdrawStagedEvents(correlationID: token)
        return PendingRunEnvelope(
            completionToken: token,
            outcome: outcome.rawValue,
            detail: terminal.detail,
            next: tool.resultInstruction(forCompletionToken: token)
        )
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
