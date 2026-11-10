import Foundation
import FoundationModelsExtras
import Testing

/// A real MLX LLM through the default pool, as a ``PooledLogits`` source: the
/// log probabilities are a full distribution, a second call gives the same
/// values, a call with several prompts gives the values of one call for each
/// prompt, and the tokenizer and the chat template work. It runs only when
/// `EXTRAS_MLX_INTEGRATION` is `1`, because it downloads about 350 MB to the
/// default Hugging Face cache and runs the model on Metal.
@Suite(
    "MLX logits real model",
    .enabled(if: ProcessInfo.processInfo.environment["EXTRAS_MLX_INTEGRATION"] == "1", "set EXTRAS_MLX_INTEGRATION=1"))
struct MLXLogitsRealModelTests {
    /// Qwen3-0.6B, 4-bit: a small MLX LLM with a chat template that reads `enable_thinking`.
    private static let ref: ModelRef = "mlx-community/Qwen3-0.6B-4bit"

    /// The count of the logits of ``ref``: the `vocab_size` of its `config.json`.
    private static let vocabularySize = 151_936

    /// The `max_position_embeddings` of the `config.json` of ``ref``.
    private static let contextLength = 40_960

    /// The largest difference between the sum of the probabilities of all
    /// vocabulary IDs and 1.
    private static let probabilitySumTolerance = 1e-3

    /// The text that the prompts of a test come from.
    private static let text = "The quick brown fox jumps over the lazy dog, and then it runs into the forest to rest."

    /// The candidates of a test: a few IDs across the vocabulary.
    private static let candidates = [0, 1_000, 50_000, 151_642]

    /// The generation prompt of the chat template of ``ref`` with reasoning off.
    private static let generationPromptWithNoReasoning = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    /// The model of each test, from the default pool.
    private let model = PooledLogitsModel(ref: ref)

    /// Gives prompts of mixed lengths from ``text``: two prompts of one
    /// length, two of a second length, and one of a third length.
    ///
    /// - Returns: The prompts, as token IDs.
    /// - Throws: The error of the load or of the tokenizer.
    private func mixedLengthPrompts() async throws -> [[Int]] {
        let tokens = try await model.tokenize(Self.text)
        let ranges = [0..<5, 0..<8, 1..<6, 2..<10, 0..<3]
        return ranges.map { Array(tokens[$0]) }
    }

    @Test("each log probability is finite and not more than 0")
    func logProbabilitiesAreFiniteAndNotPositive() async throws {
        let prompt = try await model.tokenize(Self.text)

        let values = try await model.logProbabilities(of: Self.candidates, after: [prompt]).joined()

        #expect(values.allSatisfy { $0.isFinite && $0 <= 0 })
    }

    @Test("the probabilities of all vocabulary IDs at one position sum to 1")
    func probabilitiesOfTheVocabularySumToOne() async throws {
        let prompt = try await model.tokenize(Self.text)

        let row = try #require(
            try await model.logProbabilities(of: Array(0..<Self.vocabularySize), after: [prompt]).first)

        #expect(abs(row.map(exp).reduce(0, +) - 1) <= Self.probabilitySumTolerance)
    }

    @Test("a second call with the same prompt gives the same values")
    func secondCallGivesTheSameValues() async throws {
        let prompt = try await model.tokenize(Self.text)

        let first = try await model.logProbabilities(of: Self.candidates, after: [prompt])
        let second = try await model.logProbabilities(of: Self.candidates, after: [prompt])

        #expect(first == second)
    }

    @Test("a call with mixed-length prompts gives exactly the values of one call for each prompt")
    func severalPromptsGiveTheValuesOfOneCallForEachPrompt() async throws {
        let prompts = try await mixedLengthPrompts()

        let together = try await model.logProbabilities(of: Self.candidates, after: prompts)
        let alone = try await prompts.asyncMap { prompt in
            try await model.logProbabilities(of: Self.candidates, after: [prompt])
        }
        .joined()

        #expect(together == Array(alone))
    }

    @Test("a candidate ID outside the vocabulary throws")
    func candidateOutsideTheVocabularyThrows() async throws {
        let prompt = try await model.tokenize(Self.text)

        await #expect(throws: MLXLogitsError.tokenOutsideVocabulary(Self.vocabularySize, vocabularySize: Self.vocabularySize)) {
            try await model.logProbabilities(of: [Self.vocabularySize], after: [prompt])
        }
    }

    @Test("the special-token text <|im_start|> tokenizes to one token")
    func specialTokenTextIsOneToken() async throws {
        #expect(try await model.tokenize("<|im_start|>").count == 1)
    }

    @Test("the chat template with reasoning off ends with the generation prompt")
    func chatTemplateEndsWithTheGenerationPrompt() async throws {
        let rendered = try #require(
            try await model.renderChatTemplate([["role": "user", "content": "Answer A or B."]], reasoning: false))

        #expect(rendered.hasSuffix(Self.generationPromptWithNoReasoning))
    }

    @Test("the prompt limit is the context length of the model configuration")
    func promptLimitIsTheContextLength() async throws {
        _ = try await model.tokenize(Self.text)

        #expect(model.maximumPromptTokens == Self.contextLength)
    }
}
