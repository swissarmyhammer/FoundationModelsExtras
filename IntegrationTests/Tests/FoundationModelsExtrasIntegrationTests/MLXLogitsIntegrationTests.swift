import FoundationModelsExtras
import Testing

/// Qwen3-0.6B, 4-bit: a small MLX LLM with a chat template that reads
/// `enable_thinking`. It downloads about 350 MB to the default Hugging Face
/// cache.
private let mlxLogitsKey = ModelPoolKey(ref: "mlx-community/Qwen3-0.6B-4bit", role: .llm)

/// The count of the logits of ``mlxLogitsKey``: the `vocab_size` of its `config.json`.
private let vocabularySize = 151_936

/// The `max_position_embeddings` of the `config.json` of ``mlxLogitsKey``.
private let contextLength = 40_960

/// The generation prompt of the chat template of ``mlxLogitsKey`` with reasoning off.
private let generationPromptWithNoReasoning = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

extension RealModelSuites {
    /// A real MLX LLM as a ``PooledLogits`` source: the log probabilities are
    /// a full distribution, a second call gives the same values, a call with
    /// several prompts gives the values of one call for each prompt, and the
    /// tokenizer and the chat template work. The suite loads the model one
    /// time and runs it on Metal.
    @Suite("MLX logits with a real model", .sharedLoads(SharedModel(mlxLogitsKey)))
    struct MLXLogitsIntegrationTests {
        @Test("each log probability is finite and not more than 0")
        func logProbabilitiesAreFiniteAndNotPositive() async throws {
            try await LogitsChecks.expectFiniteAndNotPositive(try LogitsChecks.sharedModel(of: mlxLogitsKey))
        }

        @Test("the probabilities of all vocabulary IDs at one position sum to 1")
        func probabilitiesOfTheVocabularySumToOne() async throws {
            try await LogitsChecks.expectProbabilitiesSumToOne(
                try LogitsChecks.sharedModel(of: mlxLogitsKey), vocabularySize: vocabularySize)
        }

        @Test("a second call with the same prompt gives the same values")
        func secondCallGivesTheSameValues() async throws {
            try await LogitsChecks.expectSecondCallGivesTheSameValues(try LogitsChecks.sharedModel(of: mlxLogitsKey))
        }

        @Test("a call with mixed-length prompts gives exactly the values of one call for each prompt")
        func severalPromptsGiveTheValuesOfOneCallForEachPrompt() async throws {
            try await LogitsChecks.expectSeveralPromptsGiveTheValuesOfOneCallForEachPrompt(
                try LogitsChecks.sharedModel(of: mlxLogitsKey))
        }

        @Test("a candidate ID outside the vocabulary throws")
        func candidateOutsideTheVocabularyThrows() async throws {
            try await expectOutsideVocabulary(vocabularySize, candidates: [vocabularySize])
        }

        @Test("a prompt token ID equal to the vocabulary size throws, with valid candidates")
        func promptTokenOutsideTheVocabularyThrows() async throws {
            try await expectOutsideVocabulary(
                vocabularySize, candidates: LogitsChecks.candidates, promptToken: vocabularySize)
        }

        @Test("a negative candidate ID throws")
        func negativeCandidateThrows() async throws {
            try await expectOutsideVocabulary(-1, candidates: [-1])
        }

        @Test("a negative prompt token ID throws, with valid candidates")
        func negativePromptTokenThrows() async throws {
            try await expectOutsideVocabulary(-1, candidates: LogitsChecks.candidates, promptToken: -1)
        }

        @Test("the special-token text <|im_start|> tokenizes to one token")
        func specialTokenTextIsOneToken() async throws {
            let model = try LogitsChecks.sharedModel(of: mlxLogitsKey)

            #expect(try await model.tokenize("<|im_start|>").count == 1)
        }

        @Test("the chat template with reasoning off ends with the generation prompt")
        func chatTemplateEndsWithTheGenerationPrompt() async throws {
            let model = try LogitsChecks.sharedModel(of: mlxLogitsKey)

            let rendered = try #require(
                try await model.renderChatTemplate(LogitsChecks.chatMessages, reasoning: false))

            #expect(rendered.hasSuffix(generationPromptWithNoReasoning))
        }

        @Test("the prompt limit is the context length of the model configuration")
        func promptLimitIsTheContextLength() throws {
            let model = try LogitsChecks.sharedModel(of: mlxLogitsKey)

            #expect(model.maximumPromptTokens == contextLength)
        }

        /// Expects that a call with `candidates`, and a prompt of
        /// ``LogitsChecks/text`` with `promptToken` added at the end, throws
        /// ``MLXLogitsError/tokenOutsideVocabulary(_:vocabularySize:)`` for
        /// `outsideID`.
        ///
        /// - Parameters:
        ///   - outsideID: The ID that the error must name.
        ///   - candidates: The candidates of the call.
        ///   - promptToken: The token that is added at the end of the prompt.
        ///     The default is the first of ``LogitsChecks/candidates``, a
        ///     valid ID.
        /// - Throws: The error of the tokenizer.
        private func expectOutsideVocabulary(
            _ outsideID: Int, candidates: [Int], promptToken: Int = LogitsChecks.candidates[0]
        ) async throws {
            let model = try LogitsChecks.sharedModel(of: mlxLogitsKey)
            let prompt = try await model.tokenize(LogitsChecks.text) + [promptToken]

            await #expect(throws: MLXLogitsError.tokenOutsideVocabulary(outsideID, vocabularySize: vocabularySize)) {
                try await model.logProbabilities(of: candidates, after: [prompt])
            }
        }
    }
}
