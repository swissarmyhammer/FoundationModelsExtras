import FoundationModels
import FoundationModelsExtras
import Testing

/// One real generation with the LLM of a hold.
enum Generation {
    /// The LLM that `hold` holds.
    ///
    /// - Parameter hold: A hold of ``IntegrationModels/llm``.
    /// - Returns: The container of the hold, as a `LanguageModel`.
    /// - Throws: A failed expectation when the container is not a `LanguageModel`.
    static func languageModel(of hold: ModelHold) throws -> any LanguageModel {
        try #require(hold.container as? any LanguageModel)
    }

    /// Asks `model` one question in a new session, with greedy sampling.
    ///
    /// - Parameters:
    ///   - prompt: The question.
    ///   - model: The LLM.
    ///   - maximumResponseTokens: The most tokens of the answer.
    /// - Returns: The text of the answer.
    /// - Throws: The error of the generation, or `CancellationError` when the
    ///   task is cancelled.
    static func respond(
        to prompt: String, with model: any LanguageModel, maximumResponseTokens: Int
    ) async throws -> String {
        try await respond(
            to: prompt, in: LanguageModelSession(model: model), maximumResponseTokens: maximumResponseTokens)
    }

    /// Asks `prompt` in `session`, with greedy sampling.
    ///
    /// - Parameters:
    ///   - prompt: The question.
    ///   - session: The session. It keeps the question and the answer in its
    ///     transcript.
    ///   - maximumResponseTokens: The most tokens of the answer.
    /// - Returns: The text of the answer.
    /// - Throws: The error of the generation, or `CancellationError` when the
    ///   task is cancelled.
    static func respond(
        to prompt: String, in session: LanguageModelSession, maximumResponseTokens: Int
    ) async throws -> String {
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
        return try await session.respond(to: prompt, options: options).content
    }
}
