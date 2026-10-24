import FoundationModels
import FoundationModelsExtras

/// A real model session with mounted tools, on
/// ``IntegrationModels/toolCallingLLM``.
enum ToolSession {
    /// The most tokens of one model answer.
    private static let maximumResponseTokens = 1024

    /// The switch that tells the Qwen3 model to write no reasoning before its
    /// answer. The reasoning costs many tokens, and these tests measure the
    /// tool hosting, not the reasoning.
    private static let noReasoningSwitch = "/no_think"

    /// What one answer of a session gave.
    struct Answer: Sendable {
        /// The text of the answer.
        let text: String
        /// The text of each tool output that the model read, in order.
        let toolOutputs: [String]
    }

    /// Asks the tool-calling LLM of `hold` `prompt` in a new session with
    /// `tools` and `instructions`.
    ///
    /// - Parameters:
    ///   - prompt: The request of the user.
    ///   - instructions: The instructions of the session.
    ///   - tools: The mounted tools of the session.
    ///   - hold: A hold of ``IntegrationModels/toolCallingLLM``.
    /// - Returns: The answer and the tool outputs of the session.
    /// - Throws: The error of the generation.
    static func answer(
        to prompt: String, instructions: String, tools: [any Tool], with hold: ModelHold
    ) async throws -> Answer {
        try await run(instructions: instructions, tools: tools, with: hold) { session in
            try await answer(to: prompt, in: session)
        }
    }

    /// Asks `prompt` in `session`, with greedy sampling.
    ///
    /// - Parameters:
    ///   - prompt: The request of the user.
    ///   - session: The session.
    /// - Returns: The answer, and each tool output of the session so far.
    /// - Throws: The error of the generation.
    static func answer(to prompt: String, in session: LanguageModelSession) async throws -> Answer {
        let text = try await Generation.respond(
            to: prompt, in: session, maximumResponseTokens: maximumResponseTokens)
        return Answer(text: text, toolOutputs: session.transcript.toolOutputTexts)
    }

    /// Makes one session on the tool-calling LLM of `hold` with `tools` and
    /// `instructions`, and runs `body` with it. The work of `body` ends before
    /// this function returns.
    ///
    /// - Parameters:
    ///   - instructions: The instructions of the session.
    ///   - tools: The mounted tools of the session.
    ///   - hold: A hold of ``IntegrationModels/toolCallingLLM``.
    ///   - body: The work with the session.
    /// - Returns: What `body` returns.
    /// - Throws: A failed expectation when the container of `hold` is not a
    ///   `LanguageModel`, or what `body` throws.
    static func run<T: Sendable>(
        instructions: String,
        tools: [any Tool],
        with hold: ModelHold,
        _ body: @escaping @Sendable (LanguageModelSession) async throws -> T
    ) async throws -> T {
        let model = try Generation.languageModel(of: hold)
        let session = LanguageModelSession(
            model: model, tools: tools, instructions: "\(instructions) \(noReasoningSwitch)")
        return try await body(session)
    }
}

extension Transcript {
    /// The text of each tool output of this transcript, in order.
    var toolOutputTexts: [String] {
        compactMap { entry in
            guard case .toolOutput(let output) = entry else { return nil }
            return output.segments.lazy.map(\.text).joined()
        }
    }
}

extension Transcript.Segment {
    /// The text of this segment. A structure gives its string value, or its
    /// JSON when it is not a string. An attachment has no text.
    fileprivate var text: String {
        switch self {
        case .text(let segment):
            segment.content
        case .structure(let segment):
            (try? segment.content.value(String.self)) ?? segment.content.jsonString
        case .attachment:
            ""
        @unknown default:
            ""
        }
    }
}
