import Foundation

/// The state that the decision questions are about.
public enum PooledDecisionState: Sendable, Hashable {
    /// The state as plain text.
    case text(String)
    /// The state as JSON text. Extras gives this text to the container
    /// unchanged: it does not parse the text and does not change its key order.
    case json(String)
}

/// The type of a decision question.
public enum PooledDecisionQuestionType: String, Sendable, Hashable {
    /// The model selects one option from the options of the question.
    case choice
    /// The model gives a level on a scale. The options are the levels, lowest
    /// first, with the keys `"0"` to `"n-1"`, where `n` is the option count.
    case score
    /// The model tells whether the instructions are true for the state. The
    /// question always has two options, with the keys `"true"` and `"false"`,
    /// in the order that the caller gives. The descriptions can be `nil`.
    /// An empty option list is not valid for this type.
    case noul
}

/// One option of a decision question.
public struct PooledDecisionOption: Sendable, Hashable {
    /// The key of the option.
    public var key: String
    /// The description of the option, or `nil` when the option has no
    /// description.
    public var description: String?

    /// Makes an option.
    ///
    /// - Parameters:
    ///   - key: The key of the option.
    ///   - description: The description of the option. The default is `nil`.
    public init(key: String, description: String? = nil) {
        self.key = key
        self.description = description
    }
}

/// One question about a ``PooledDecisionState``.
public struct PooledDecisionQuestion: Sendable, Hashable {
    /// The ID of the question. The answer to the question has the same ID.
    public var id: String
    /// The type of the question.
    public var type: PooledDecisionQuestionType
    /// The instructions that tell the model what to decide.
    public var instructions: String
    /// The options of the question, in order.
    ///
    /// For a ``PooledDecisionQuestionType/score`` question, the options are the
    /// levels, lowest first, with the keys `"0"` to `"n-1"`. For a
    /// ``PooledDecisionQuestionType/noul`` question, there are always two
    /// options with the keys `"true"` and `"false"`, in the order that the
    /// caller gives; an empty list is not valid. Extras does not validate
    /// these rules: the container decides.
    public var options: [PooledDecisionOption]

    /// Makes a question.
    ///
    /// - Parameters:
    ///   - id: The ID of the question.
    ///   - type: The type of the question.
    ///   - instructions: The instructions that tell the model what to decide.
    ///   - options: The options of the question, in order.
    public init(id: String, type: PooledDecisionQuestionType, instructions: String, options: [PooledDecisionOption]) {
        self.id = id
        self.type = type
        self.instructions = instructions
        self.options = options
    }
}

/// The answer to one ``PooledDecisionQuestion``.
public struct PooledDecisionAnswer: Sendable, Hashable {
    /// The ID of the question.
    public var id: String
    /// One probability for each option of the question, in option order.
    /// For a `score` question, this is the level order, lowest first.
    public var probabilities: [Double]
    /// The expected value of a `score` question, in level-index units (`0`
    /// to `n-1`, where `n` is the level count). The value is `nil` for the
    /// other question types.
    public var expectedValue: Double?

    /// Makes an answer.
    ///
    /// - Parameters:
    ///   - id: The ID of the question.
    ///   - probabilities: One probability for each option, in option order.
    ///   - expectedValue: The expected value of a `score` question, in
    ///     level-index units, or `nil` for the other question types.
    public init(id: String, probabilities: [Double], expectedValue: Double?) {
        self.id = id
        self.probabilities = probabilities
        self.expectedValue = expectedValue
    }
}

/// A model that answers decision questions natively: the model itself makes
/// the prompt and reads the answer, from the decision type in its metadata.
///
/// ``PooledDecisionsModel`` conforms to it, and a loader gives a container
/// that conforms to it for a key of the `.llm` role when the model can answer
/// decision questions.
///
/// The requirements are functions, not properties, because
/// ``PooledDecisionsModel`` loads its model on the first call.
public protocol PooledDecisions: Sendable {
    /// Gives the decision type name of the model.
    ///
    /// - Returns: The decision type name, or `nil` when the model has no decision type.
    /// - Throws: An error if the source cannot read the decision type.
    func decisionType() async throws -> String?

    /// Answers questions about a state.
    ///
    /// Give each question a different ID to get one answer for each
    /// question. A repeated ID gives fewer answers than questions. A repeated
    /// option key in a question can make the probabilities of its answer sum
    /// to more than 1.
    ///
    /// The source does not check the request against the limits of the
    /// model, for example the largest option count of a question. A request
    /// that the model cannot do throws the error of the model, unchanged.
    ///
    /// - Parameters:
    ///   - state: The state that the questions are about.
    ///   - questions: The questions, in order.
    /// - Returns: One answer for each question, in question order, when each
    ///   question has a different ID.
    /// - Throws: An error if the source cannot answer the questions, for
    ///   example the error of the model for a request that the model cannot do.
    func decide(state: PooledDecisionState, questions: [PooledDecisionQuestion]) async throws -> [PooledDecisionAnswer]
}

/// A decision source that keeps one ``ModelHold`` of an LLM, so the model
/// stays resident while a copy of the source exists. Each call goes to the
/// container of the hold, which conforms to ``PooledDecisions`` and has a
/// decision type.
///
/// A model made from a name loads nothing when you make it. Its first call
/// acquires the model from the pool with a key of the `.llm` role, one time
/// only, also when first calls run at the same time. All copies of one model
/// share that one hold, and the hold goes with the last copy.
///
/// The first call of each model also reads the decision type of the
/// container. When the container has no decision type, that call throws
/// ``PooledDecisionsModelError/notDecisionCapable(_:)``.
///
/// ```swift
/// let model = PooledDecisionsModel(ref: "org/decision-model-GGUF")   // loads nothing
/// let question = PooledDecisionQuestion(
///     id: "spam",
///     type: .noul,
///     instructions: "Is the ticket spam?",
///     options: [PooledDecisionOption(key: "true"), PooledDecisionOption(key: "false")]
/// )
/// let answers = try await model.decide(state: .text("Win a free phone!"), questions: [question])
/// ```
public struct PooledDecisionsModel: PooledDecisions {
    /// The Hugging Face name of the model.
    public let ref: ModelRef

    /// The hold of the model after the decision-type check, which all copies
    /// of this model share.
    private let resident: ResidentHold<LoadedDecisions>

    /// Makes a source of the LLM `ref`. This loads nothing: the first call
    /// acquires the model from `pool`.
    ///
    /// - Parameters:
    ///   - ref: The Hugging Face name of the LLM.
    ///   - pool: The pool that loads the model with its loader. The default is
    ///     ``ModelPool/shared``.
    public init(ref: ModelRef, pool: ModelPool = .shared) {
        let key = ModelPoolKey(ref: ref, role: .llm)
        self.ref = ref
        resident = ResidentHold {
            try await LoadedDecisions(hold: try await pool.acquire(key)).checkedDecisionType()
        }
    }

    /// Makes a source that keeps `hold`. Use this when you acquire the model
    /// with your own byte counts. The first call reads the decision type of
    /// the container.
    ///
    /// - Parameter hold: A hold of an LLM.
    /// - Throws: ``PooledDecisionsModelError/notDecisionCapable(_:)`` when the
    ///   container of `hold` does not conform to ``PooledDecisions``.
    public init(hold: ModelHold) throws {
        let loaded = try LoadedDecisions(hold: hold)
        ref = loaded.hold.key.ref
        resident = ResidentHold { try await loaded.checkedDecisionType() }
    }

    /// Gives the decision type name of the container. The first call of a
    /// model loads the model when it has no hold yet, and checks the decision type.
    ///
    /// - Returns: The decision type name of the container.
    /// - Throws: The error of the load or of the model; or
    ///   ``PooledDecisionsModelError/notDecisionCapable(_:)`` when the
    ///   container does not conform to ``PooledDecisions`` or has no decision type.
    public func decisionType() async throws -> String? {
        try await resident.loaded().decisions.decisionType()
    }

    /// Answers questions about a state, with the container. The first call of
    /// a model loads the model when it has no hold yet, and checks the
    /// decision type. Extras gives `state` and `questions` to the container
    /// unchanged.
    ///
    /// - Parameters:
    ///   - state: The state that the questions are about.
    ///   - questions: The questions, in order.
    /// - Returns: One answer for each question, in question order.
    /// - Throws: The error of the load or of the model; or
    ///   ``PooledDecisionsModelError/notDecisionCapable(_:)`` when the
    ///   container does not conform to ``PooledDecisions`` or has no decision type.
    public func decide(state: PooledDecisionState, questions: [PooledDecisionQuestion]) async throws -> [PooledDecisionAnswer] {
        try await resident.loaded().decisions.decide(state: state, questions: questions)
    }
}

/// A hold of an LLM, and its container as a ``PooledDecisions``.
private struct LoadedDecisions: Sendable {
    /// The hold of the model. The model stays resident while this value exists.
    let hold: ModelHold
    /// The container of the hold, as a decision source.
    let decisions: any PooledDecisions

    /// Takes the container of `hold` as a decision source.
    ///
    /// - Parameter hold: A hold of an LLM.
    /// - Throws: ``PooledDecisionsModelError/notDecisionCapable(_:)`` with the
    ///   name of the key of `hold`, when the container of `hold` does not
    ///   conform to ``PooledDecisions``.
    init(hold: ModelHold) throws {
        guard let decisions = hold.container as? any PooledDecisions else {
            throw PooledDecisionsModelError.notDecisionCapable(hold.key.ref)
        }
        self.hold = hold
        self.decisions = decisions
    }

    /// Checks that the container has a decision type.
    ///
    /// - Returns: This value, when the container has a decision type.
    /// - Throws: The error of the container; or
    ///   ``PooledDecisionsModelError/notDecisionCapable(_:)`` with the name of
    ///   the key of ``hold``, when the container has no decision type.
    func checkedDecisionType() async throws -> LoadedDecisions {
        guard try await decisions.decisionType() != nil else {
            throw PooledDecisionsModelError.notDecisionCapable(hold.key.ref)
        }
        return self
    }
}

/// An error of ``PooledDecisionsModel``.
public enum PooledDecisionsModelError: Error, Equatable, LocalizedError {
    /// The container of the model does not conform to ``PooledDecisions``, or
    /// it has no decision type.
    case notDecisionCapable(ModelRef)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .notDecisionCapable(let ref):
            return """
                The container of \(ref.stringValue) does not conform to PooledDecisions, or it has no \
                decision type, thus the model cannot answer decision questions. The first loader of a key \
                gives the container of all holds, so the loader of this LLM key must return a \
                PooledDecisions, and the model must have a decision type in its metadata.
                """
        }
    }
}
