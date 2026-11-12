import Foundation
import FoundationModelsExtras
import Testing

/// The checks that each logits suite does on a real ``PooledLogitsModel``,
/// whatever its runtime.
enum LogitsChecks {
    /// The largest difference between the sum of the probabilities of all
    /// vocabulary IDs and 1.
    private static let probabilitySumTolerance = 1e-3

    /// The text that the prompts of a check come from.
    static let text = "The quick brown fox jumps over the lazy dog, and then it runs into the forest to rest."

    /// The candidates of a check: a few IDs across the vocabulary.
    static let candidates = [0, 1_000, 50_000, 151_642]

    /// The message of the chat-template checks.
    static let chatMessages = [["role": "user", "content": "Answer A or B."]]

    /// The ranges of the tokens of ``text`` that give prompts of mixed
    /// lengths: two prompts of one length, two of a second length, and one of
    /// a third length.
    private static let mixedLengthRanges = [0..<5, 0..<8, 1..<6, 2..<10, 0..<3]

    /// A source of the shared model of `key` of the running suite.
    ///
    /// - Parameter key: A model that the ``SharedLoadsTrait`` of the suite declares.
    /// - Returns: The source. It keeps a copy of the shared hold.
    /// - Throws: A failed expectation when the suite does not load `key`, or
    ///   ``PooledLogitsModelError/notLogitsCapable(_:)``.
    static func sharedModel(of key: ModelPoolKey) throws -> PooledLogitsModel {
        try PooledLogitsModel(hold: SharedModels.required().hold(of: key))
    }

    /// Expects that each log probability of ``candidates`` after ``text`` is
    /// finite and not more than 0.
    ///
    /// - Parameter model: The model of the suite.
    /// - Throws: The error of the tokenizer or of the model.
    static func expectFiniteAndNotPositive(_ model: PooledLogitsModel) async throws {
        let prompt = try await model.tokenize(text)

        let values = try await model.logProbabilities(of: candidates, after: [prompt]).joined()

        #expect(values.count == candidates.count)
        #expect(values.allSatisfy { $0.isFinite && $0 <= 0 })
    }

    /// Expects that the probabilities of all vocabulary IDs after ``text``
    /// sum to 1.
    ///
    /// - Parameters:
    ///   - model: The model of the suite.
    ///   - vocabularySize: The count of the logits of the model.
    /// - Throws: The error of the tokenizer or of the model.
    static func expectProbabilitiesSumToOne(_ model: PooledLogitsModel, vocabularySize: Int) async throws {
        let prompt = try await model.tokenize(text)

        let row = try #require(
            try await model.logProbabilities(of: Array(0..<vocabularySize), after: [prompt]).first)

        #expect(row.count == vocabularySize)
        #expect(abs(row.map(exp).reduce(0, +) - 1) <= probabilitySumTolerance)
    }

    /// Expects that a second call with the same prompt gives the same values.
    ///
    /// - Parameter model: The model of the suite.
    /// - Throws: The error of the tokenizer or of the model.
    static func expectSecondCallGivesTheSameValues(_ model: PooledLogitsModel) async throws {
        let prompt = try await model.tokenize(text)

        let first = try await model.logProbabilities(of: candidates, after: [prompt])
        let second = try await model.logProbabilities(of: candidates, after: [prompt])

        #expect(first == second)
    }

    /// Expects that a call with prompts of mixed lengths gives exactly the
    /// values of one call for each prompt.
    ///
    /// - Parameter model: The model of the suite.
    /// - Throws: The error of the tokenizer or of the model.
    static func expectSeveralPromptsGiveTheValuesOfOneCallForEachPrompt(_ model: PooledLogitsModel) async throws {
        let tokens = try await model.tokenize(text)
        let prompts = mixedLengthRanges.map { Array(tokens[$0]) }

        let together = try await model.logProbabilities(of: candidates, after: prompts)

        #expect(together.count == prompts.count)
        for (prompt, row) in zip(prompts, together) {
            let alone = try await model.logProbabilities(of: candidates, after: [prompt])
            #expect(alone == [row])
        }
    }
}
