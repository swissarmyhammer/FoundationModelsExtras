import FoundationModels

/// Gives a failed tool call to the model as the output of the call.
///
/// `LanguageModelSession` runs the tool calls of one round together. When one
/// call throws, the session cancels the other calls and ends the submission,
/// so the model never reads the failure. Thus a failure must not leave
/// `Tool.call` as a throw on the tool list that the model sees. A
/// cancellation still throws, or cancellation stops working.
///
/// Only the tool list of the model gets this decorator, as the outermost
/// layer. A caller that is not the model uses ``throwingTool(of:)`` to keep
/// the throw.
enum ToolFailureDelivery {
    /// Wraps `tool` in the decorator that gives a failure to the model.
    ///
    /// A `String` tool becomes a ``FailureDeliveringTextTool``, so its output
    /// stays text. Any other tool becomes a ``FailureDeliveringResultTool``.
    ///
    /// - Parameter tool: The mounted tool.
    /// - Returns: The decorated tool.
    static func makeWrapped(tool: any Tool) -> any Tool {
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard let textTool = tool as? any Tool<T.Arguments, String> else {
                return FailureDeliveringResultTool<T.Arguments, T.Output>(wrapped: tool)
            }
            return FailureDeliveringTextTool(wrapped: textTool)
        }
        return open(tool)
    }

    /// The tool beneath the decorator, which still throws.
    ///
    /// - Parameter tool: A decorated tool, or any other tool.
    /// - Returns: The tool beneath the decorator, or `tool` when it has no
    ///   decorator.
    static func throwingTool(of tool: any Tool) -> any Tool {
        (tool as? any FailureDeliveringTool)?.throwingTool ?? tool
    }
}

/// A decorator that gives a failure of the tool beneath to the model.
protocol FailureDeliveringTool: Tool {
    /// The tool beneath this decorator, which still throws.
    var throwingTool: any Tool { get }
}

/// The decorator for a `String` tool. The failure text is the `String`
/// output, so the transcript records text.
struct FailureDeliveringTextTool<
    Arguments: ConvertibleFromGeneratedContent
>: FailureDeliveringTool, SubmissionBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, String>

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }
    var throwingTool: any Tool { wrapped }

    /// Calls `wrapped`, and gives the output to ``ToolResultAppendBoundary``.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of `wrapped`, or the text of its failure.
    /// - Throws: A `CancellationError`, unchanged.
    func call(arguments: Arguments) async throws -> String {
        let text = try await ToolCallResult { try await wrapped.call(arguments: arguments) }.text
        await ToolResultAppendBoundary.current?.deliver(
            result: ToolResultAppend(toolName: name, arguments: arguments, text: text))
        return text
    }
}

/// The decorator for a tool whose output is not `String`. The output is a
/// ``ToolCallResult``.
struct FailureDeliveringResultTool<
    Arguments: ConvertibleFromGeneratedContent, WrappedOutput: PromptRepresentable
>: FailureDeliveringTool, SubmissionBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, WrappedOutput>

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }
    var throwingTool: any Tool { wrapped }

    /// Calls `wrapped`, and gives the result to ``ToolResultAppendBoundary``.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of `wrapped`, or the text of its failure.
    /// - Throws: A `CancellationError`, unchanged.
    func call(arguments: Arguments) async throws -> ToolCallResult<WrappedOutput> {
        let result = try await ToolCallResult { try await wrapped.call(arguments: arguments) }
        await ToolResultAppendBoundary.current?.deliver(
            result: ToolResultAppend(toolName: name, arguments: arguments, result: result))
        return result
    }
}

/// The output of one tool call as the model reads it: the output of the
/// tool, or the text of the failure.
///
/// It conforms to `ConvertibleToGeneratedContent` only when `Output` does.
/// Thus the transcript records a structure or text, the same as for the tool
/// beneath.
enum ToolCallResult<Output: PromptRepresentable>: PromptRepresentable {
    /// The call returned `Output`.
    case output(Output)

    /// The call failed. The model reads this description of the error.
    case failure(String)

    /// Runs one call, and keeps its output or the text of its failure.
    ///
    /// - Parameter call: The call.
    /// - Throws: A `CancellationError` from `call`, unchanged. Each other
    ///   error becomes ``failure(_:)``.
    init(catching call: () async throws -> Output) async throws {
        do {
            self = .output(try await call())
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            self = .failure(String(describing: error))
        }
    }

    /// The prompt of the output, or the failure text.
    var promptRepresentation: Prompt {
        switch self {
        case .output(let output):
            output.promptRepresentation
        case .failure(let text):
            text.promptRepresentation
        }
    }
}

extension ToolCallResult where Output == String {
    /// The output, or the failure text.
    var text: String {
        switch self {
        case .output(let text), .failure(let text):
            text
        }
    }
}

extension ToolCallResult: InstructionsRepresentable, ConvertibleToGeneratedContent
where Output: ConvertibleToGeneratedContent {
    /// The generated content of the output, or the failure text.
    var generatedContent: GeneratedContent {
        switch self {
        case .output(let output):
            output.generatedContent
        case .failure(let text):
            text.generatedContent
        }
    }
}
