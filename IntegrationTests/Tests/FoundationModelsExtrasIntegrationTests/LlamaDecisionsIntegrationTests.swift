import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import FoundationModelsLlamaCpp
import Testing

/// h2o-lightning-4b, Q4_K_M: a GGUF decision model of the `h2o-lightning`
/// type, at its pinned revision. It downloads about 2.7 GB to the default
/// Hugging Face cache.
private let llamaDecisionsKey = ModelPoolKey(
    ref: "h2oai/h2o-lightning-4b-gguf/h2o-lightning-4b-Q4_K_M.gguf@61f8d8b7a8c2d84426d0d143ca187f65d235934b",
    role: .llm)

/// The bytes that the pool counts for the weights and one session of
/// ``llamaDecisionsKey``. This is a rough upper limit.
private let llamaDecisionsFootprintBytes: Int64 = 4 << 30

/// The decision type name of ``llamaDecisionsKey``.
private let llamaDecisionsType = "h2o-lightning"

/// The largest difference between the sum of the probabilities of one answer
/// and 1.
private let probabilitySumTolerance = 1e-3

/// The state of the questions.
private let ticket = PooledDecisionState.text(
    "Congratulations! You won a free phone. Click the link and enter your card number to claim it today.")

/// A noul question with the `true` option first.
private let spamTrueFirst = PooledDecisionQuestion(
    id: "spam", type: .noul, instructions: "Is the ticket spam?",
    options: [PooledDecisionOption(key: "true"), PooledDecisionOption(key: "false")])

/// The question of ``spamTrueFirst`` with the `false` option first.
private let spamFalseFirst = PooledDecisionQuestion(
    id: spamTrueFirst.id, type: .noul, instructions: spamTrueFirst.instructions,
    options: spamTrueFirst.options.reversed())

/// A choice question.
private let topic = PooledDecisionQuestion(
    id: "topic", type: .choice, instructions: "What is the topic of the ticket?",
    options: [
        PooledDecisionOption(key: "billing", description: "A question about a bill or a payment."),
        PooledDecisionOption(key: "prize", description: "A message about a prize or a gift."),
        PooledDecisionOption(key: "bug", description: "A report of a defect in the product."),
    ])

/// A score question.
private let urgency = PooledDecisionQuestion(
    id: "urgency", type: .score, instructions: "How urgent is the ticket?",
    options: [
        PooledDecisionOption(key: "0", description: "Not urgent."),
        PooledDecisionOption(key: "1", description: "Somewhat urgent."),
        PooledDecisionOption(key: "2", description: "Very urgent."),
    ])

/// An option count that is more than the limit of each decision type of
/// llama.cpp, which is never more than 255.
private let tooManyOptionCount = 300

/// A choice question with ``tooManyOptionCount`` options.
private let tooManyOptions = PooledDecisionQuestion(
    id: "code", type: .choice, instructions: "Which code fits the ticket?",
    options: (0..<tooManyOptionCount).map { PooledDecisionOption(key: "code\($0)") })

extension RealModelSuites {
    /// A real GGUF decision model through the GGUF loader, as a
    /// ``PooledDecisions`` source: the decision type, and the answers of a
    /// noul, a choice and a score question. The suite loads the model one
    /// time, runs it on Metal, and evicts it after its last test.
    @Suite(
        "LlamaCpp decisions with a real model",
        .sharedLoads(
            SharedModel(
                llamaDecisionsKey, footprint: llamaDecisionsFootprintBytes,
                loader: HubModelLoader(gguf: LlamaCppModelLoader()))))
    struct LlamaDecisionsIntegrationTests {
        @Test("the decision type is h2o-lightning")
        func decisionTypeIsH2OLightning() async throws {
            #expect(try await Self.sharedModel().decisionType() == llamaDecisionsType)
        }

        @Test("each answer of a noul, a choice and a score question is a distribution over its options")
        func eachAnswerIsADistribution() async throws {
            let questions = [spamTrueFirst, topic, urgency]

            let answers = try await Self.sharedModel().decide(state: ticket, questions: questions)

            #expect(answers.map(\.id) == questions.map(\.id))
            for (question, answer) in zip(questions, answers) {
                Self.expectDistribution(answer, of: question)
            }
        }

        @Test("a score answer has an expected value in level-index units, and the other answers have none")
        func onlyAScoreAnswerHasAnExpectedValue() async throws {
            let questions = [spamTrueFirst, topic, urgency]

            let answers = try await Self.sharedModel().decide(state: ticket, questions: questions)

            try #require(answers.count == questions.count)
            #expect(answers[0].expectedValue == nil)
            #expect(answers[1].expectedValue == nil)
            let expectedValue = try #require(answers[2].expectedValue)
            #expect((0...Double(urgency.options.count - 1)).contains(expectedValue))
        }

        @Test("the probabilities of a noul answer follow the option order of the question")
        func noulProbabilitiesFollowTheOptionOrder() async throws {
            let model = try Self.sharedModel()

            let trueFirst = try #require(try await model.decide(state: ticket, questions: [spamTrueFirst]).first)
            let falseFirst = try #require(try await model.decide(state: ticket, questions: [spamFalseFirst]).first)

            #expect(falseFirst.probabilities == trueFirst.probabilities.reversed())
        }

        @Test("a second call with the same state and questions gives the same answers")
        func secondCallGivesTheSameAnswers() async throws {
            let model = try Self.sharedModel()
            let questions = [spamTrueFirst, topic, urgency]

            let first = try await model.decide(state: ticket, questions: questions)
            let second = try await model.decide(state: ticket, questions: questions)

            #expect(first == second)
        }

        @Test("a question with more options than the model accepts throws the error of llama.cpp, unchanged")
        func tooManyOptionsThrowsTheErrorOfLlamaCpp() async throws {
            let model = try Self.sharedModel()

            let error = await #expect(throws: LlamaError.self) {
                try await model.decide(state: ticket, questions: [tooManyOptions])
            }

            let reason: String? =
                if case .decisionRequestNotValid(let reason) = error { reason } else { nil }
            #expect(
                try #require(reason).hasPrefix(
                    "question \"code\": the question has \(tooManyOptionCount) options, and the model accepts at most "))
        }

        // MARK: Helpers

        /// A source of the shared decision model of the suite.
        ///
        /// - Returns: The source. It keeps a copy of the shared hold.
        /// - Throws: A failed expectation when the suite does not load the
        ///   model, or ``PooledDecisionsModelError/notDecisionCapable(_:)``.
        private static func sharedModel() throws -> PooledDecisionsModel {
            try PooledDecisionsModel(hold: SharedModels.required().hold(of: llamaDecisionsKey))
        }

        /// Expects that `answer` has one finite probability in 0...1 for each
        /// option of `question`, and that the probabilities sum to 1.
        ///
        /// - Parameters:
        ///   - answer: The answer.
        ///   - question: The question of the answer.
        private static func expectDistribution(_ answer: PooledDecisionAnswer, of question: PooledDecisionQuestion) {
            #expect(answer.probabilities.count == question.options.count)
            #expect(answer.probabilities.allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(abs(answer.probabilities.reduce(0, +) - 1) <= probabilitySumTolerance)
        }
    }

    /// A real GGUF model with no decision type through the GGUF loader: the
    /// first call of a ``PooledDecisionsModel`` throws. The test loads the
    /// model in a pool of its own and waits for the eviction of the model.
    @Suite("LlamaCpp decisions with a real model that has no decision type")
    struct LlamaNoDecisionTypeIntegrationTests {
        @Test("a GGUF model with no decision type throws notDecisionCapable")
        func modelWithNoDecisionTypeThrows() async throws {
            try ModelAvailability.requireMetalDevice()
            let key = ModelPoolKey(ref: singleFileRef, role: .llm)
            let pool = ModelPool(loader: HubModelLoader(gguf: LlamaCppModelLoader()))

            await #expect(throws: PooledDecisionsModelError.notDecisionCapable(singleFileRef)) {
                try await PooledDecisionsModel(ref: singleFileRef, pool: pool).decisionType()
            }
            try await IntegrationModels.waitForEviction(of: key, in: pool)
        }
    }
}
