import Foundation
import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import FoundationModelsLlamaCpp
import Testing

/// A real GGUF LLM through a pool with the GGUF loader, as a
/// ``PooledLogits`` source: the log probabilities are a full distribution, a
/// second call gives the same values, a call with several prompts gives the
/// values of one call for each prompt, and a prompt from the chat template
/// gives a row. It runs only when `EXTRAS_GGUF_INTEGRATION` is `1`, because
/// it downloads about 1.3 GB to the default Hugging Face cache and runs the
/// model on Metal.
@Suite(
    "LlamaCpp logits real model",
    .enabled(
        if: ProcessInfo.processInfo.environment["EXTRAS_GGUF_INTEGRATION"] == "1", "set EXTRAS_GGUF_INTEGRATION=1"))
struct LlamaLogitsRealModelTests {
    /// decider-2b, Q4_K_M: a Qwen3.5-2B model, at its pinned revision.
    private static let ref: ModelRef =
        "Mapika/decider-2b-GGUF/decider-2b-v12-Q4_K_M.gguf@0df001b8fe4e5298c5dd45d875d3795fcdaea0ab"

    /// The largest difference between the sum of the probabilities of all
    /// vocabulary IDs and 1.
    private static let probabilitySumTolerance = 1e-3

    /// The text that the prompts of a test come from.
    private static let text = "The quick brown fox jumps over the lazy dog, and then it runs into the forest to rest."

    /// The candidates of a test: a few IDs across the vocabulary.
    private static let candidates = [0, 1_000, 50_000, 151_642]

    /// The pool of each test, over the GGUF loader and the default Hugging
    /// Face cache. All tests share it, thus the model loads one time.
    private static let pool = ModelPool(loader: HubModelLoader(gguf: LlamaCppModelLoader()))

    /// The model of each test.
    private let model = PooledLogitsModel(ref: ref, pool: pool)

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

        #expect(values.count == Self.candidates.count)
        #expect(values.allSatisfy { $0.isFinite && $0 <= 0 })
    }

    @Test("the probabilities of all vocabulary IDs at one position sum to 1")
    func probabilitiesOfTheVocabularySumToOne() async throws {
        let hold = try await Self.pool.acquire(ModelPoolKey(ref: Self.ref, role: .llm))
        let vocabularySize = try #require(hold.container as? LlamaLanguageModel).tokenizer().vocabularySize
        let model = try PooledLogitsModel(hold: hold)
        let prompt = try await model.tokenize(Self.text)

        let row = try #require(
            try await model.logProbabilities(of: Array(0..<vocabularySize), after: [prompt]).first)

        #expect(row.count == vocabularySize)
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

        #expect(together.count == prompts.count)
        for (prompt, row) in zip(prompts, together) {
            let alone = try await model.logProbabilities(of: Self.candidates, after: [prompt])
            #expect(alone == [row])
        }
    }

    @Test("a prompt from the chat template gives a row of finite values, and the limit is the context size")
    func chatTemplatePromptGivesARow() async throws {
        let rendered = try #require(
            try await model.renderChatTemplate([["role": "user", "content": "Answer A or B."]], reasoning: false))
        let prompt = try await model.tokenize(rendered)
        let candidates = try await model.tokenize("AB")

        let row = try #require(try await model.logProbabilities(of: candidates, after: [prompt]).first)

        #expect(row.count == candidates.count)
        #expect(row.allSatisfy { $0.isFinite && $0 <= 0 })
        #expect(try #require(model.maximumPromptTokens) >= prompt.count)
    }
}
