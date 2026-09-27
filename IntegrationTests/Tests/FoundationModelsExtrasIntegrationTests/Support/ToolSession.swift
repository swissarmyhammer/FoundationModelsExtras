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

    /// Loads the tool-calling LLM in `pool`, and asks it `prompt` in a new
    /// session with `tools` and `instructions`. Releases the hold on return.
    ///
    /// - Parameters:
    ///   - prompt: The request of the user.
    ///   - instructions: The instructions of the session.
    ///   - tools: The mounted tools of the session.
    ///   - pool: The pool of the test.
    /// - Returns: The answer and the tool outputs of the session.
    /// - Throws: The error of the load or of the generation.
    static func answer(
        to prompt: String, instructions: String, tools: [any Tool], in pool: ModelPool
    ) async throws -> Answer {
        try await run(instructions: instructions, tools: tools, in: pool) { session in
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

    /// Loads the tool-calling LLM in `pool`, makes one session with `tools`
    /// and `instructions`, and runs `body` with it in the queue of the hold.
    /// Releases the hold on return.
    ///
    /// - Parameters:
    ///   - instructions: The instructions of the session.
    ///   - tools: The mounted tools of the session.
    ///   - pool: The pool of the test.
    ///   - body: The work with the session.
    /// - Returns: What `body` returns.
    /// - Throws: The error of the load, or what `body` throws.
    static func run<T: Sendable>(
        instructions: String,
        tools: [any Tool],
        in pool: ModelPool,
        _ body: @escaping @Sendable (LanguageModelSession) async throws -> T
    ) async throws -> T {
        let hold = try await IntegrationModels.acquire(
            key: IntegrationModels.toolCallingLLM, in: pool,
            loader: MLXPooledLoader(languageModelCapabilities: MLXPooledLoader.toolCallingCapabilities),
            footprint: IntegrationModels.toolCallingFootprintBytes)
        let model = try Generation.languageModel(of: hold)
        return try await hold.queue.submit {
            let session = LanguageModelSession(
                model: model, tools: tools, instructions: "\(instructions) \(noReasoningSwitch)")
            return try await body(session)
        }
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
