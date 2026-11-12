import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import FoundationModelsLlamaCpp
import Testing

/// decider-2b, Q4_K_M: a Qwen3.5-2B GGUF model, at its pinned revision. It
/// downloads about 1.3 GB to the default Hugging Face cache.
private let llamaLogitsKey = ModelPoolKey(
    ref: "Mapika/decider-2b-GGUF/decider-2b-v12-Q4_K_M.gguf@0df001b8fe4e5298c5dd45d875d3795fcdaea0ab", role: .llm)

/// The bytes that the pool counts for the weights and one session of
/// ``llamaLogitsKey``. This is a rough upper limit.
private let llamaLogitsFootprintBytes: Int64 = 2 << 30

extension RealModelSuites {
    /// A real GGUF LLM through the GGUF loader, as a ``PooledLogits`` source:
    /// the log probabilities are a full distribution, a second call gives the
    /// same values, a call with several prompts gives the values of one call
    /// for each prompt, and a prompt from the chat template gives a row. The
    /// suite loads the model one time and runs it on Metal.
    @Suite(
        "LlamaCpp logits with a real model",
        .sharedLoads(
            SharedModel(
                llamaLogitsKey, footprint: llamaLogitsFootprintBytes,
                loader: HubModelLoader(gguf: LlamaCppModelLoader()))))
    struct LlamaLogitsIntegrationTests {
        @Test("each log probability is finite and not more than 0")
        func logProbabilitiesAreFiniteAndNotPositive() async throws {
            try await LogitsChecks.expectFiniteAndNotPositive(try LogitsChecks.sharedModel(of: llamaLogitsKey))
        }

        @Test("the probabilities of all vocabulary IDs at one position sum to 1")
        func probabilitiesOfTheVocabularySumToOne() async throws {
            let hold = try SharedModels.required().hold(of: llamaLogitsKey)
            let vocabularySize = try #require(hold.container as? LlamaLanguageModel).tokenizer().vocabularySize

            try await LogitsChecks.expectProbabilitiesSumToOne(
                try PooledLogitsModel(hold: hold), vocabularySize: vocabularySize)
        }

        @Test("a second call with the same prompt gives the same values")
        func secondCallGivesTheSameValues() async throws {
            try await LogitsChecks.expectSecondCallGivesTheSameValues(try LogitsChecks.sharedModel(of: llamaLogitsKey))
        }

        @Test("a call with mixed-length prompts gives exactly the values of one call for each prompt")
        func severalPromptsGiveTheValuesOfOneCallForEachPrompt() async throws {
            try await LogitsChecks.expectSeveralPromptsGiveTheValuesOfOneCallForEachPrompt(
                try LogitsChecks.sharedModel(of: llamaLogitsKey))
        }

        @Test("a prompt from the chat template gives a row of finite values, and the limit is the context size")
        func chatTemplatePromptGivesARow() async throws {
            let model = try LogitsChecks.sharedModel(of: llamaLogitsKey)
            let rendered = try #require(
                try await model.renderChatTemplate(LogitsChecks.chatMessages, reasoning: false))
            let prompt = try await model.tokenize(rendered)
            let candidates = try await model.tokenize("AB")

            try await LogitsChecks.expectFiniteAndNotPositive(model, candidates: candidates, after: prompt)

            #expect(try #require(model.maximumPromptTokens) >= prompt.count)
        }
    }
}
