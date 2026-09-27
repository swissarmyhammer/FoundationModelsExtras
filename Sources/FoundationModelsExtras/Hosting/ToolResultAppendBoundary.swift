import FoundationModels

/// One tool result, as the model reads it next.
public struct ToolResultAppend: Sendable {
    /// The name of the tool that the model called.
    public let toolName: String

    /// The arguments of the call, or `nil` when the arguments type cannot
    /// give its generated content.
    public let arguments: GeneratedContent?

    /// The transcript segment that holds the result.
    public let segment: Transcript.Segment

    /// The result as text. The session counts its tokens.
    public let text: String

    /// Makes the value for a text result.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool that the model called.
    ///   - arguments: The decoded arguments of the call.
    ///   - text: The text that the model reads.
    public init(toolName: String, arguments: Any, text: String) {
        self.toolName = toolName
        self.arguments = Self.generatedContent(of: arguments)
        self.segment = .text(Transcript.TextSegment(content: text))
        self.text = text
    }

    /// Makes the value for a result that is not text.
    ///
    /// A result that gives its generated content becomes a structured
    /// segment. Any other result becomes a text segment of its prompt.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool that the model called.
    ///   - arguments: The decoded arguments of the call.
    ///   - result: The result that the model reads.
    public init(toolName: String, arguments: Any, result: some PromptRepresentable) {
        self.toolName = toolName
        self.arguments = Self.generatedContent(of: arguments)
        guard let content = Self.generatedContent(of: result) else {
            let text = String(describing: result.promptRepresentation)
            self.segment = .text(Transcript.TextSegment(content: text))
            self.text = text
            return
        }
        self.segment = .structure(Transcript.StructuredSegment(schemaName: toolName, content: content))
        self.text = content.jsonString
    }

    /// The generated content of `value`, when its type can give it.
    ///
    /// - Parameter value: The arguments or the result of a call.
    /// - Returns: The generated content, or `nil`.
    private static func generatedContent(of value: Any) -> GeneratedContent? {
        (value as? any ConvertibleToGeneratedContent)?.generatedContent
    }
}

/// Gives the tool results of one model call to the session of that call.
///
/// The session binds ``current`` around each model call. A tool decorator
/// reads ``current`` and gives each result to it. A task-local value is
/// used because it reaches `Tool.call` through the model runtime.
public struct ToolResultAppendBoundary: Sendable {
    /// The boundary of the model call that the current task runs in, or
    /// `nil` outside a model call.
    @TaskLocal public static var current: ToolResultAppendBoundary?

    /// The session operation that gets each result.
    private let receive: @Sendable (ToolResultAppend) async -> Void

    /// Makes the boundary of one model call.
    ///
    /// - Parameter receive: The session operation that gets each result.
    public init(receive: @escaping @Sendable (ToolResultAppend) async -> Void) {
        self.receive = receive
    }

    /// Gives one tool result to the session.
    ///
    /// - Parameter result: The result that the model reads next.
    public func deliver(result: ToolResultAppend) async {
        await receive(result)
    }
}
