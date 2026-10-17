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
        try await session.respond(to: prompt, options: greedyOptions(maximumResponseTokens)).content
    }

    /// Asks `model` one question in a new session, with greedy sampling, and
    /// streams the answer. Each snapshot of the stream goes to `snapshots`
    /// when it arrives, thus a test sees the decode while it runs.
    ///
    /// - Parameters:
    ///   - prompt: The question.
    ///   - model: The LLM.
    ///   - maximumResponseTokens: The most tokens of the answer.
    ///   - snapshots: Gets the text of each snapshot, in order.
    ///   - afterFirstSnapshot: Runs one time, after the first snapshot went to
    ///     `snapshots`. The stream continues when it returns. A test holds the
    ///     generation at that point with a latch. The default does nothing.
    /// - Returns: The text of the last snapshot.
    /// - Throws: The error of the generation, or `CancellationError` when the
    ///   task is cancelled. A cancel ends the stream of the MLX model with no
    ///   error, thus this function then throws `CancellationError`, as
    ///   ``respond(to:with:maximumResponseTokens:)`` does.
    static func stream(
        _ prompt: String, with model: any LanguageModel, maximumResponseTokens: Int, into snapshots: EventLog<String>,
        afterFirstSnapshot: @Sendable () async -> Void = {}
    ) async throws -> String {
        let stream = LanguageModelSession(model: model)
            .streamResponse(to: prompt, options: greedyOptions(maximumResponseTokens))
        var text = ""
        var isFirst = true
        for try await snapshot in stream {
            text = snapshot.content
            snapshots.record(text)
            if isFirst {
                isFirst = false
                await afterFirstSnapshot()
            }
        }
        try Task.checkCancellation()
        return text
    }

    /// The options of a greedy generation.
    ///
    /// - Parameter maximumResponseTokens: The most tokens of the answer.
    /// - Returns: The options.
    private static func greedyOptions(_ maximumResponseTokens: Int) -> GenerationOptions {
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
    }
}
