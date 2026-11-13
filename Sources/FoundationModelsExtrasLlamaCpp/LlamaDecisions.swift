import Foundation
import FoundationModelsExtras
import FoundationModelsLlamaCpp
import os

/// A GGUF decision model answers decision questions natively, thus a
/// ``PooledDecisionsModel`` of an `.llm` key that ``LlamaCppModelLoader``
/// loads works.
///
/// `LlamaLanguageModel.decide(state:questions:)` of FoundationModelsLlamaCpp
/// does the work in this process, with typed calls into llama.cpp. The
/// decision code of llama.cpp makes the prompts from the decision metadata of
/// the GGUF file and reads the logits of the labels. This conformance only
/// maps each request type to its llama.cpp type, and each answer back.
///
/// A model has a decision type name only when its GGUF file has a decision
/// type that `decide` supports. Thus a model with no decision type, or with a
/// type that `decide` does not support, is not decision-capable, and
/// ``PooledDecisionsModel`` throws
/// ``PooledDecisionsModelError/notDecisionCapable(_:)``.
extension LlamaLanguageModel: PooledDecisions {
    /// Gives the decision type name of the model: the `<arch>.decision.type`
    /// text of its GGUF file, for example `"h2o-lightning"`.
    ///
    /// The initializer of the model reads the decision type from the
    /// metadata, thus this call loads no weights.
    ///
    /// - Returns: The decision type name, or `nil` when the GGUF file has no
    ///   decision type, or has a type that `decide` does not support.
    public func decisionType() async throws -> String? {
        (decisionType as LlamaDecisionType?)?.pooledDecisionType
    }

    /// Answers questions about a state with the decision code of llama.cpp.
    ///
    /// A JSON state goes to llama.cpp as the same text, with its key order.
    /// The probabilities of each answer are in the option order of its
    /// question, also for a noul question. The expected value of a score
    /// answer is the expected level, in level-index units.
    ///
    /// For the `lev` type, the probability of `true` of a noul answer is the
    /// expected value of the rating scale of the model, from 0 to 1, and not
    /// a true probability. `decide` gives this value, and this conformance
    /// does not change it.
    ///
    /// llama.cpp keeps one question for each ID: the last question with that
    /// ID, at the position of the first one. Thus a repeated ID gives fewer
    /// answers than questions, and each answer uses the options of the last
    /// question with its ID. llama.cpp also keeps one option for each key:
    /// the repeated keys of a question get the same probability, thus the
    /// probabilities can sum to more than 1.
    ///
    /// The call does not check the request against the limits of the model.
    /// llama.cpp checks it, and its error comes to the caller unchanged. For
    /// example, a question with more options than the model accepts throws
    /// `LlamaError.decisionRequestNotValid(reason:)`, and the reason gives
    /// the number of options and the limit of the model.
    ///
    /// - Parameters:
    ///   - state: The state that the questions are about.
    ///   - questions: The questions, in order, each with a different ID.
    /// - Returns: The answers in the order of llama.cpp: one answer for each
    ///   question, in question order, when each question has a different ID.
    /// - Throws: ``LlamaDecisionsError/noulOptionsNotValid(questionID:)`` for
    ///   a noul question whose option keys are not `"true"` and `"false"`; or
    ///   the error of `LlamaLanguageModel.decide(state:questions:)`, for
    ///   example `LlamaError.decisionRequestNotValid(reason:)` when llama.cpp
    ///   refuses the request.
    public func decide(state: PooledDecisionState, questions: [PooledDecisionQuestion]) async throws
        -> [PooledDecisionAnswer]
    {
        let answers = try await decide(
            state: LlamaDecisionState(state), questions: try questions.map(LlamaDecisionQuestion.init))
        return PooledDecisionAnswer.answers(of: answers.map(LlamaDecisionResult.init), to: questions)
    }
}

extension LlamaDecisionType {
    /// The decision type name of a ``PooledDecisions`` source of this type:
    /// the raw value when `LlamaLanguageModel.decide(state:questions:)`
    /// supports the type, else `nil`.
    var pooledDecisionType: String? {
        isSupportedByDecide ? rawValue : nil
    }
}

extension LlamaDecisionState {
    /// Makes the llama.cpp state of a decision state. A JSON state keeps its
    /// text unchanged.
    ///
    /// - Parameter state: The decision state.
    init(_ state: PooledDecisionState) {
        switch state {
        case .text(let text):
            self = .text(text)
        case .json(let json):
            self = .json(json)
        }
    }
}

extension LlamaDecisionQuestion {
    /// The option key of the `true` answer of a noul question.
    static let noulTrueKey = "true"

    /// The option key of the `false` answer of a noul question.
    static let noulFalseKey = "false"

    /// The option keys of a noul question.
    static let noulKeys: Set<String> = [noulTrueKey, noulFalseKey]

    /// Makes the llama.cpp question of a decision question, with the same ID,
    /// instructions and options, in order.
    ///
    /// - Parameter question: The decision question.
    /// - Throws: ``LlamaDecisionsError/noulOptionsNotValid(questionID:)`` for
    ///   a noul question that does not have exactly two options with the keys
    ///   `"true"` and `"false"`.
    init(_ question: PooledDecisionQuestion) throws {
        let keys = question.options.map(\.key)
        guard question.type != .noul || (keys.count == Self.noulKeys.count && Set(keys) == Self.noulKeys) else {
            throw LlamaDecisionsError.noulOptionsNotValid(questionID: question.id)
        }
        self.init(
            id: question.id, kind: Kind(question.type), instructions: question.instructions,
            options: question.options.map { LlamaDecisionOption(key: $0.key, description: $0.description) })
    }
}

extension LlamaDecisionQuestion.Kind {
    /// Makes the llama.cpp kind of a question type.
    ///
    /// - Parameter type: The question type.
    init(_ type: PooledDecisionQuestionType) {
        switch type {
        case .choice:
            self = .choice
        case .score:
            self = .score
        case .noul:
            self = .noul
        }
    }
}

/// The parts of a llama.cpp answer that the map to a ``PooledDecisionAnswer``
/// reads.
struct LlamaDecisionResult {
    /// The ID of the question of the answer.
    let questionID: String
    /// The probabilities of the answer, as llama.cpp gives them.
    let probabilities: [Double]
    /// The outcome of the answer.
    let outcome: LlamaDecisionAnswer.Outcome
}

extension LlamaDecisionResult {
    /// Takes the parts of a llama.cpp answer.
    ///
    /// - Parameter answer: The llama.cpp answer.
    init(_ answer: LlamaDecisionAnswer) {
        self.init(questionID: answer.questionID, probabilities: answer.probabilities, outcome: answer.outcome)
    }
}

extension PooledDecisionAnswer {
    /// The logger of an answer that has no question.
    private static let logger = Logger(subsystem: "FoundationModelsExtrasLlamaCpp", category: "decisions")

    /// Makes the answers of a call from the llama.cpp answers, in the order
    /// of llama.cpp.
    ///
    /// Each answer uses the question with its ID. For a repeated ID, that is
    /// the last question with the ID, because llama.cpp keeps the content of
    /// the last one.
    ///
    /// - Parameters:
    ///   - results: The llama.cpp answers, in the order of llama.cpp.
    ///   - questions: The questions of the call, in order.
    /// - Returns: One answer for each llama.cpp answer whose ID is the ID of
    ///   a question.
    static func answers(of results: [LlamaDecisionResult], to questions: [PooledDecisionQuestion])
        -> [PooledDecisionAnswer]
    {
        let lastQuestionByID = Dictionary(questions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return results.compactMap { result in
            guard let question = lastQuestionByID[result.questionID] else {
                assertionFailure("llama.cpp gave an answer for the question ID \(result.questionID), which no question has")
                logger.error("llama.cpp gave an answer for a question ID that no question has; the answer is dropped")
                return nil
            }
            return PooledDecisionAnswer(
                question: question, probabilities: result.probabilities, outcome: result.outcome)
        }
    }

    /// Makes the answer of a question from the probabilities and the outcome
    /// of the llama.cpp answer.
    ///
    /// llama.cpp gives the probabilities of a noul answer in the order
    /// `false`, `true`. This answer gives them in the option order of the
    /// question: the probability of `true` for the `"true"` key, and 1 minus
    /// it for the `"false"` key. The expected value of a score answer is the
    /// expected level of llama.cpp: the sum of each level index, from 0,
    /// times its probability. That is level-index units, thus the value needs
    /// no conversion.
    ///
    /// - Parameters:
    ///   - question: The question of the answer.
    ///   - probabilities: The probabilities of the llama.cpp answer.
    ///   - outcome: The outcome of the llama.cpp answer.
    init(question: PooledDecisionQuestion, probabilities: [Double], outcome: LlamaDecisionAnswer.Outcome) {
        switch outcome {
        case .noul(let probability):
            let trueKey = LlamaDecisionQuestion.noulTrueKey
            self.init(
                id: question.id,
                probabilities: question.options.map { $0.key == trueKey ? probability : 1 - probability },
                expectedValue: nil)
        case .score(let value, _, _):
            self.init(id: question.id, probabilities: probabilities, expectedValue: value)
        case .choice:
            self.init(id: question.id, probabilities: probabilities, expectedValue: nil)
        }
    }
}

/// An error of the decision source of a GGUF decision model.
public enum LlamaDecisionsError: Error, Equatable, LocalizedError {
    /// The noul question with this ID does not have exactly two options with
    /// the keys `"true"` and `"false"`.
    case noulOptionsNotValid(questionID: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .noulOptionsNotValid(let questionID):
            return """
                The noul question "\(questionID)" must have two options, with the keys "true" and "false".
                """
        }
    }
}
