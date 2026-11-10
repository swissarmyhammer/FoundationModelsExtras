import Foundation

/// A causal language model that gives next-token log probabilities.
///
/// ``PooledLogitsModel`` conforms to it, and a loader gives a container that
/// conforms to it for a key of the `.llm` role when the model can give log
/// probabilities.
///
/// A source does not keep state between calls that changes the results.
/// It can keep a cache, but each call must give the same result with and without the cache.
public protocol PooledLogits: Sendable {
    /// The largest number of tokens in one prompt, or `nil` for no fixed limit.
    var maximumPromptTokens: Int? { get }

    /// Tokenizes text.
    ///
    /// The result has no BOS token and no EOS token.
    /// Special-token text, for example `<|im_start|>`, becomes the special token,
    /// as Hugging Face `encode(text, add_special_tokens=False)` does.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The token IDs of the text.
    /// - Throws: An error if the source cannot tokenize the text.
    func tokenize(_ text: String) async throws -> [Int]

    /// Renders the chat template of the model as text.
    ///
    /// The text includes the generation prompt, thus the next token is the first token of the reply.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat, in order. Each message has the
    ///     keys `role` and `content` only. The role is, for example,
    ///     `"system"`, `"user"` or `"assistant"`.
    ///   - reasoning: `true` to let the model reason before it replies, `false` to turn reasoning off.
    /// - Returns: The rendered text, or `nil` if the model has no chat template.
    /// - Throws: An error if the source cannot render the template.
    func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String?

    /// Gives the log probabilities of candidate tokens at the last position of each prompt.
    ///
    /// The source evaluates each prompt exactly as given. It adds no BOS token.
    /// Each log probability is under the full next-token distribution (a
    /// log-softmax over all the logits), not only over the candidates.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read.
    ///   - prompts: The prompts, each as token IDs.
    /// - Returns: One row for each prompt, in the order of `prompts`.
    ///   Each row has one log probability for each candidate, in the order of `candidates`.
    /// - Throws: An error if the source cannot evaluate a prompt.
    func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]]
}

/// A log-probability source that keeps one ``ModelHold`` of an LLM, so the
/// model stays resident while a copy of the source exists. Each call goes to
/// the container of the hold, which conforms to ``PooledLogits``.
///
/// A model made from a name loads nothing when you make it. Its first call
/// acquires the model from the pool with a key of the `.llm` role, one time
/// only, also when first calls run at the same time. All copies of one model
/// share that one hold, and the hold goes with the last copy.
///
/// ```swift
/// let model = PooledLogitsModel(ref: "mlx-community/Qwen3-4B-4bit")   // loads nothing
/// let candidates = try await model.tokenize("AB")                      // loads the model
/// let prompt = try await model.tokenize("Answer A or B: ")
/// let rows = try await model.logProbabilities(of: candidates, after: [prompt])
/// ```
public struct PooledLogitsModel: PooledLogits {
    /// The Hugging Face name of the model.
    public let ref: ModelRef

    /// The hold of the model, which all copies of this model share.
    private let resident: ResidentHold<LoadedLogits>

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
        resident = ResidentHold { try LoadedLogits(hold: try await pool.acquire(key)) }
    }

    /// Makes a source that keeps `hold`. Use this when you acquire the model
    /// with your own byte counts.
    ///
    /// - Parameter hold: A hold of an LLM.
    /// - Throws: ``PooledLogitsModelError/notLogitsCapable(_:)`` when the
    ///   container of `hold` does not conform to ``PooledLogits``.
    public init(hold: ModelHold) throws {
        let loaded = try LoadedLogits(hold: hold)
        ref = loaded.hold.key.ref
        resident = ResidentHold(loaded: loaded)
    }

    /// The largest number of tokens in one prompt, or `nil` for no fixed limit.
    ///
    /// This property does not load the model. A model made from a name gives
    /// `nil` before its first call, and the limit of the container after it.
    public var maximumPromptTokens: Int? {
        resident.current?.logits.maximumPromptTokens
    }

    /// Tokenizes text with the tokenizer of the container. The first call of
    /// a model made from a name loads the model first.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The token IDs of the text, with no BOS token and no EOS token.
    /// - Throws: The error of the load or of the model; or
    ///   ``PooledLogitsModelError/notLogitsCapable(_:)`` when the loaded
    ///   container does not conform to ``PooledLogits``.
    public func tokenize(_ text: String) async throws -> [Int] {
        try await resident.loaded().logits.tokenize(text)
    }

    /// Renders the chat template of the container as text, with the
    /// generation prompt. The first call of a model made from a name loads
    /// the model first.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat, in order. Each message has the
    ///     keys `role` and `content` only.
    ///   - reasoning: `true` to let the model reason before it replies, `false` to turn reasoning off.
    /// - Returns: The rendered text, or `nil` if the model has no chat template.
    /// - Throws: The error of the load or of the model; or
    ///   ``PooledLogitsModelError/notLogitsCapable(_:)`` when the loaded
    ///   container does not conform to ``PooledLogits``.
    public func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String? {
        try await resident.loaded().logits.renderChatTemplate(messages, reasoning: reasoning)
    }

    /// Gives the log probabilities of candidate tokens at the last position of
    /// each prompt, from the container. The first call of a model made from a
    /// name loads the model first.
    ///
    /// Each call records one logits span, a call count and a duration, with
    /// the model ref and the counts of the call. The span also holds the load
    /// when the call loads the model. The telemetry holds no text and no
    /// token ID.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read.
    ///   - prompts: The prompts, each as token IDs.
    /// - Returns: One row for each prompt, in the order of `prompts`.
    ///   Each row has one log probability for each candidate, in the order of `candidates`.
    /// - Throws: The error of the load or of the model; or
    ///   ``PooledLogitsModelError/notLogitsCapable(_:)`` when the loaded
    ///   container does not conform to ``PooledLogits``.
    public func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]] {
        try await LogitsTelemetry.traceLogProbabilities(of: ref, candidates: candidates, prompts: prompts) {
            try await resident.loaded().logits.logProbabilities(of: candidates, after: prompts)
        }
    }
}

/// A hold of an LLM, and its container as a ``PooledLogits``.
private struct LoadedLogits: Sendable {
    /// The hold of the model. The model stays resident while this value exists.
    let hold: ModelHold
    /// The container of the hold, as a log-probability source.
    let logits: any PooledLogits

    /// Takes the container of `hold` as a log-probability source.
    ///
    /// - Parameter hold: A hold of an LLM.
    /// - Throws: ``PooledLogitsModelError/notLogitsCapable(_:)`` with the
    ///   name of the key of `hold`, when the container of `hold` does not
    ///   conform to ``PooledLogits``.
    init(hold: ModelHold) throws {
        guard let logits = hold.container as? any PooledLogits else {
            throw PooledLogitsModelError.notLogitsCapable(hold.key.ref)
        }
        self.hold = hold
        self.logits = logits
    }
}

/// An error of ``PooledLogitsModel``.
public enum PooledLogitsModelError: Error, Equatable, LocalizedError {
    /// The container of the model does not conform to ``PooledLogits``.
    case notLogitsCapable(ModelRef)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .notLogitsCapable(let ref):
            return """
                The container of \(ref.stringValue) does not conform to PooledLogits, thus the model \
                cannot give log probabilities. The first loader of a key gives the container of all \
                holds, so the loader of this LLM key must return a PooledLogits.
                """
        }
    }
}
