import FixtureSupport
import Foundation
import FoundationModelsExtras
import FoundationModelsLlamaCpp
import LlamaCppTestFixtures
import Testing

@testable import FoundationModelsExtrasLlamaCpp

/// The parts of the ``PooledDecisions`` conformance of `LlamaLanguageModel`
/// that need no weights: the decision type name of each type, the map of
/// each request type to its llama.cpp type, and the map of each answer back.
///
/// The model tests use the vocab-only Qwen3.5 GGUF file of
/// `LlamaCppTestFixtures`, which has no decision type. The initializer of the
/// model reads the metadata only, thus no test loads weights or uses the
/// network.
@Suite("LlamaCpp decisions: the decision type and the maps")
struct LlamaDecisionsTests {
    /// The vocab-only GGUF file of the tests.
    private static let vocabulary = "qwen35"

    /// The probability of `true` of the noul answers.
    private static let noulProbability = 0.75

    /// The probabilities of a score answer, lowest level first.
    private static let scoreProbabilities = [0.1, 0.2, 0.7]

    /// The expected level of a score answer.
    private static let scoreValue = 1.6

    /// The probabilities of a choice answer, in option order.
    private static let choiceProbabilities = [0.3, 0.7]

    /// The instructions of the questions.
    private static let instructions = "Is the ticket spam?"

    /// The JSON text of a state, with a key order that is not sorted.
    private static let jsonState = #"{"zeta":1,"alpha":[true,null]}"#

    /// The options of a noul question, `true` first.
    private static let trueFirst = [PooledDecisionOption(key: "true"), PooledDecisionOption(key: "false")]

    /// The options of a noul question, `false` first.
    private static let falseFirst = [PooledDecisionOption(key: "false"), PooledDecisionOption(key: "true")]

    /// The options of a score question, lowest level first.
    private static let levels = [
        PooledDecisionOption(key: "0", description: "low"),
        PooledDecisionOption(key: "1", description: "medium"),
        PooledDecisionOption(key: "2", description: "high"),
    ]

    /// The options of a choice question.
    private static let choices = [
        PooledDecisionOption(key: "billing", description: "A billing question."),
        PooledDecisionOption(key: "bug"),
    ]

    /// Makes a model of the vocab-only GGUF file, which has no decision type.
    ///
    /// - Returns: The model.
    /// - Throws: The error of a fixture or of the initializer.
    private static func makeModel() throws -> LlamaLanguageModel {
        try LlamaLanguageModel(gguf: LlamaCppTestFixtures.vocabURL(named: vocabulary).resolvingSymlinksInPath())
    }

    /// Makes a question of the tests.
    ///
    /// - Parameters:
    ///   - type: The type of the question.
    ///   - options: The options of the question.
    /// - Returns: The question.
    private static func question(_ type: PooledDecisionQuestionType, options: [PooledDecisionOption])
        -> PooledDecisionQuestion
    {
        PooledDecisionQuestion(id: type.rawValue, type: type, instructions: instructions, options: options)
    }

    // MARK: The decision type

    @Test(
        "the decision type name is the raw value of a type that decide supports, and nil for the other types",
        arguments: LlamaDecisionType.allCases)
    func decisionTypeNameOfEachType(type: LlamaDecisionType) {
        #expect(type.pooledDecisionType == (type.isSupportedByDecide ? type.rawValue : nil))
    }

    @Test("a model with no decision type gives no decision type name")
    func modelWithNoDecisionTypeGivesNil() async throws {
        let model = try Self.makeModel()

        #expect(try await model.decisionType() == nil)
    }

    @Test("a PooledDecisionsModel of a GGUF file with no decision type throws notDecisionCapable")
    func pooledDecisionsModelOfAModelWithNoDecisionTypeThrows() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        try FileManager.default.copyItem(
            at: LlamaCppTestFixtures.vocabURL(named: Self.vocabulary).resolvingSymlinksInPath(), to: file)
        let loader = HubModelLoader(cacheDirectory: root, gguf: LlamaCppModelLoader(cacheDirectory: root))
        let ref = ModelRef(file.path)
        let model = PooledDecisionsModel(ref: ref, pool: ModelPool(loader: loader))

        await #expect(throws: PooledDecisionsModelError.notDecisionCapable(ref)) {
            try await model.decisionType()
        }
    }

    // MARK: The state

    @Test("a text state maps to the same text")
    func textStateMapsToText() {
        #expect(LlamaDecisionState(PooledDecisionState.text(Self.instructions)) == .text(Self.instructions))
    }

    @Test("a JSON state maps to the same JSON text, with its key order")
    func jsonStateMapsToTheSameText() {
        #expect(LlamaDecisionState(PooledDecisionState.json(Self.jsonState)) == .json(Self.jsonState))
    }

    // MARK: The question

    @Test(
        "each question type maps to the kind of the same name",
        arguments: [PooledDecisionQuestionType.choice, .score, .noul])
    func questionTypeMapsToKind(type: PooledDecisionQuestionType) throws {
        let options = type == .noul ? Self.trueFirst : Self.choices

        let question = try LlamaDecisionQuestion(Self.question(type, options: options))

        #expect(question.kind.rawValue == type.rawValue)
    }

    @Test("a question maps with its ID, its instructions and its options in order")
    func questionMapsWithItsFields() throws {
        let question = try LlamaDecisionQuestion(Self.question(.score, options: Self.levels))

        #expect(
            question
                == LlamaDecisionQuestion(
                    id: PooledDecisionQuestionType.score.rawValue, kind: .score, instructions: Self.instructions,
                    options: [
                        LlamaDecisionOption(key: "0", description: "low"),
                        LlamaDecisionOption(key: "1", description: "medium"),
                        LlamaDecisionOption(key: "2", description: "high"),
                    ]))
    }

    @Test(
        "a noul question with keys that are not true and false throws",
        arguments: [
            [PooledDecisionOption(key: "yes"), PooledDecisionOption(key: "no")],
            [PooledDecisionOption(key: "true")],
            [PooledDecisionOption(key: "true"), PooledDecisionOption(key: "true")],
            [],
        ])
    func noulQuestionWithOtherKeysThrows(options: [PooledDecisionOption]) {
        #expect(throws: LlamaDecisionsError.noulOptionsNotValid(questionID: PooledDecisionQuestionType.noul.rawValue)) {
            try LlamaDecisionQuestion(Self.question(.noul, options: options))
        }
    }

    // MARK: The answer

    @Test("a noul answer with true first gives the probability of true first")
    func noulAnswerWithTrueFirst() {
        let answer = PooledDecisionAnswer(
            question: Self.question(.noul, options: Self.trueFirst),
            probabilities: [1 - Self.noulProbability, Self.noulProbability],
            outcome: .noul(Self.noulProbability))

        #expect(answer.probabilities == [Self.noulProbability, 1 - Self.noulProbability])
    }

    @Test("a noul answer with false first gives the probability of false first")
    func noulAnswerWithFalseFirst() {
        let answer = PooledDecisionAnswer(
            question: Self.question(.noul, options: Self.falseFirst),
            probabilities: [1 - Self.noulProbability, Self.noulProbability],
            outcome: .noul(Self.noulProbability))

        #expect(answer.probabilities == [1 - Self.noulProbability, Self.noulProbability])
    }

    @Test("a noul answer has no expected value")
    func noulAnswerHasNoExpectedValue() {
        let answer = PooledDecisionAnswer(
            question: Self.question(.noul, options: Self.trueFirst),
            probabilities: [1 - Self.noulProbability, Self.noulProbability],
            outcome: .noul(Self.noulProbability))

        #expect(answer.expectedValue == nil)
    }

    @Test("a score answer gives the expected level and the probabilities of the levels")
    func scoreAnswerGivesTheExpectedLevel() {
        let answer = PooledDecisionAnswer(
            question: Self.question(.score, options: Self.levels),
            probabilities: Self.scoreProbabilities,
            outcome: .score(value: Self.scoreValue, confidence: 1, legend: Self.levels.map(\.description)))

        #expect(
            answer
                == PooledDecisionAnswer(
                    id: PooledDecisionQuestionType.score.rawValue, probabilities: Self.scoreProbabilities,
                    expectedValue: Self.scoreValue))
    }

    @Test("a choice answer gives the probabilities in option order and no expected value")
    func choiceAnswerGivesTheProbabilities() {
        let answer = PooledDecisionAnswer(
            question: Self.question(.choice, options: Self.choices),
            probabilities: Self.choiceProbabilities,
            outcome: .choice(key: "bug", confidence: 1))

        #expect(
            answer
                == PooledDecisionAnswer(
                    id: PooledDecisionQuestionType.choice.rawValue, probabilities: Self.choiceProbabilities,
                    expectedValue: nil))
    }

    // MARK: The answers of a call

    @Test("the answers of a call keep the order of llama.cpp, and each answer uses the question of its ID")
    func answersKeepTheOrderOfLlamaCppAndFindTheirQuestionByID() {
        let results = [
            LlamaDecisionResult(
                questionID: PooledDecisionQuestionType.score.rawValue, probabilities: Self.scoreProbabilities,
                outcome: .score(value: Self.scoreValue, confidence: 1, legend: Self.levels.map(\.description))),
            LlamaDecisionResult(
                questionID: PooledDecisionQuestionType.noul.rawValue,
                probabilities: [1 - Self.noulProbability, Self.noulProbability],
                outcome: .noul(Self.noulProbability)),
        ]

        let answers = PooledDecisionAnswer.answers(
            of: results,
            to: [Self.question(.noul, options: Self.falseFirst), Self.question(.score, options: Self.levels)])

        #expect(
            answers == [
                PooledDecisionAnswer(
                    id: PooledDecisionQuestionType.score.rawValue, probabilities: Self.scoreProbabilities,
                    expectedValue: Self.scoreValue),
                PooledDecisionAnswer(
                    id: PooledDecisionQuestionType.noul.rawValue,
                    probabilities: [1 - Self.noulProbability, Self.noulProbability], expectedValue: nil),
            ])
    }

    @Test("the answer of a repeated question ID uses the options of the last question with that ID")
    func repeatedQuestionIDUsesTheLastQuestion() {
        let result = LlamaDecisionResult(
            questionID: PooledDecisionQuestionType.noul.rawValue,
            probabilities: [1 - Self.noulProbability, Self.noulProbability],
            outcome: .noul(Self.noulProbability))

        let answers = PooledDecisionAnswer.answers(
            of: [result],
            to: [Self.question(.noul, options: Self.trueFirst), Self.question(.noul, options: Self.falseFirst)])

        #expect(answers.map(\.probabilities) == [[1 - Self.noulProbability, Self.noulProbability]])
    }

    @Test("the error of a noul question with keys that are not valid names the question")
    func noulOptionsNotValidDescription() {
        let description = LlamaDecisionsError.noulOptionsNotValid(questionID: "spam").errorDescription

        #expect(
            description
                == """
                The noul question "spam" must have two options, with the keys "true" and "false".
                """)
    }
}
