import Foundation
import FoundationModels

/// A decorator that runs each call of the tool to completion and returns its
/// output, unless the tool gives a background mount for that call. A call
/// with no progress for the whole timeout ends with
/// ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
///
/// The body runs inside the model call of its session, so it holds the model
/// for each other session on that model until it returns. Long work belongs
/// in a background tool.
struct RunToCompletionRunner<
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
    /// else to completion. See ``ToolMounting/call(_:arguments:site:mount:)``.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool, or the envelope of a background call.
    /// - Throws: The error of the tool, or
    ///   ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
    func call(arguments: Arguments) async throws -> String {
        try await ToolMounting.call(
            wrapped, arguments: arguments, site: site, mount: ToolMount(mode: .runToCompletion, timeout: timeout))
    }

    /// Runs one call and returns the output of the tool. The span of the call
    /// records the outcome of the run, so a timeout is not a failure.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool.
    /// - Throws: The error of the tool, or
    ///   ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
    func callToCompletion(arguments: Arguments) async throws -> String {
        try await ToolCallSpan.withSpan(
            tracer: site.tracer, toolName: wrapped.name, sessionID: site.sessionID, runKind: .foreground
        ) { span in
            let run = ToolRun(wrapped: wrapped, arguments: arguments, site: site, mountTimeout: timeout)
            await run.open()
            let settlement = await run.execute(arguments: arguments)
            if let outcome = settlement.terminal.outcome {
                ToolCallSpan.record(outcome: outcome, on: span)
            }
            return try settlement.result.get()
        }
    }
}
