import Foundation
import FoundationModels

/// A decorator that binds a new ``ToolContext`` around each call of a tool
/// whose output is not `String`, and returns the output as is. It posts no
/// events.
struct ContextBindingTool<
    Arguments: ConvertibleFromGeneratedContent, Output: PromptRepresentable
>: Tool, SubmissionBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, Output>

    /// Where the tool runs.
    private let site: MountSite

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Wraps `wrapped`.
    ///
    /// - Parameters:
    ///   - wrapped: The tool.
    ///   - site: Where the tool runs.
    init(wrapping wrapped: any Tool<Arguments, Output>, site: MountSite) {
        self.wrapped = wrapped
        self.site = site
    }

    /// Runs one call in a new context, records its outcome on its span, and
    /// posts its report when the call attached a record.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool, as is.
    /// - Throws: The error of the tool, as is.
    func call(arguments: Arguments) async throws -> Output {
        try await ToolCallSpan.withSpan(
            tracer: site.tracer, toolName: wrapped.name, sessionID: site.sessionID, runKind: .foreground
        ) { span in
            let settlement = await settle(arguments: arguments)
            ToolCallSpan.record(outcome: settlement.recordedOutcome, on: span)
            await site.sink.postToolCallReport(closing: settlement.closeRecord, attachments: settlement.attachments)
            return try settlement.outcome.get()
        }
    }

    /// Runs one call in a new context, between an open and a close record,
    /// and takes the records that the call attached.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: How the call ended, and what it attached.
    func settle(arguments: Arguments) async -> BindingSettlement<Output> {
        let state = ToolCallState()
        let context = ToolContext(
            calling: wrapped, on: site, sink: site.sink, completionToken: RunPlane.makeCompletionToken(), state: state)
        let openRecord = ToolInvocationRecord(opening: context)
        await site.sink.post(invocation: openRecord)
        let outcome = await withTaskCancellationHandler {
            await Self.result {
                try await ToolContext.$current.withValue(context) {
                    try await wrapped.call(arguments: arguments)
                }
            }
        } onCancel: {
            state.requestCancel()
        }
        // A record that the tool attaches after this point belongs to no
        // settlement, and is dropped.
        let attachments = state.drainAttachments()
        let closeRecord = openRecord.closed(at: Date())
        await site.sink.post(invocation: closeRecord)
        return BindingSettlement(outcome: outcome, attachments: attachments, closeRecord: closeRecord)
    }

    /// The output of `call`, or its error. A `Result` keeps the error, so the
    /// close record is posted on the throw path too.
    private static func result(of call: () async throws -> Output) async -> Result<Output, any Error> {
        do {
            return .success(try await call())
        } catch {
            return .failure(error)
        }
    }
}

/// How one bound call ended.
struct BindingSettlement<Output> {
    /// The output of the tool, or the error that ended the call.
    let outcome: Result<Output, any Error>

    /// The records that the tool attached, in call order.
    let attachments: [ToolCallAttachment]

    /// The close record of the call, already posted.
    let closeRecord: ToolInvocationRecord

    /// The outcome on the span: succeeded for an output, failed for an error.
    var recordedOutcome: OperationOutcome {
        switch outcome {
        case .success: .succeeded
        case .failure: .failed
        }
    }
}
