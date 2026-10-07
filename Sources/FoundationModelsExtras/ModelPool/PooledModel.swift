import FoundationModels

/// An LLM of a ``ModelPool``, by its Hugging Face name, as a FoundationModels
/// `LanguageModel`. A pooled model loads nothing when you make it.
///
/// Give it to a `LanguageModelSession`. The first generation call of the
/// session acquires the model from the pool, one time only, also when first
/// calls run at the same time. All copies of one pooled model share that one
/// hold, thus the model stays resident while a copy exists, for example the
/// copy in a session. Each generation call is one job in the queue of the
/// model, so the calls of all users of one model run one at a time.
///
/// ```swift
/// let qwen = PooledModel(ref: "mlx-community/Qwen3-4B-4bit")   // loads nothing
/// let session = LanguageModelSession(model: qwen, instructions: "Answer in one word.")
/// let text = try await session.respond(to: "What color is the sky?").content   // loads the model
/// ```
///
/// ``session(instructions:tools:)`` makes a ``PooledSession``, which keeps a
/// hold of its own and can fork its transcript.
public struct PooledModel: LanguageModel {
    /// The executor that sends each generation call to the queue of the model.
    public typealias Executor = PooledModelExecutor

    /// The pool that loads the model.
    private let pool: ModelPool

    /// The LLM.
    private let key: ModelPoolKey

    /// The hold of the model, which all copies of this pooled model share.
    private let resident: ResidentHold<LoadedLanguageModel>

    /// What the model can do. A session reads this before the model loads,
    /// thus it comes from the initializer, not from the loaded model.
    public let capabilities: LanguageModelCapabilities

    /// The cache key of the executor: the LLM.
    public var executorConfiguration: PooledModelExecutor.Configuration {
        PooledModelExecutor.Configuration(key: key)
    }

    /// Makes a model of the LLM `ref`. This loads nothing: the first
    /// generation call, or the first ``session(instructions:tools:)`` call,
    /// loads the model into `pool`.
    ///
    /// - Parameters:
    ///   - ref: The Hugging Face name of the LLM.
    ///   - pool: The pool that loads the model with its loader. The default is
    ///     ``ModelPool/shared``.
    ///   - capabilities: What the loaded model can do. The default is guided
    ///     generation, tool calls and reasoning: the capabilities of each LLM
    ///     that ``MLXModelLoader`` gives.
    public init(
        ref: ModelRef, pool: ModelPool = .shared,
        capabilities: LanguageModelCapabilities = LanguageModelCapabilities(MLXModelLoader.languageModelCapabilities)
    ) {
        let key = ModelPoolKey(ref: ref, role: .llm)
        self.pool = pool
        self.key = key
        self.capabilities = capabilities
        self.resident = ResidentHold { try LoadedLanguageModel(hold: try await pool.acquire(key)) }
    }

    /// Makes a session of the model. The call acquires the model from the
    /// pool, and loads it when it is not resident. The session keeps its hold,
    /// so the model stays resident while the session exists.
    ///
    /// - Parameters:
    ///   - instructions: The instructions of the session, or `nil` for none.
    ///   - tools: The tools that the model can call in the session.
    /// - Returns: A new session with an empty transcript.
    /// - Throws: The error of the load, or
    ///   ``PooledSessionError/notALanguageModel(key:containerType:)`` when the
    ///   container of the model is not a FoundationModels `LanguageModel`.
    public func session(instructions: String? = nil, tools: [any Tool] = []) async throws -> PooledSession {
        let hold = try await pool.acquire(key)
        return try PooledSession(hold: hold, pool: pool, tools: tools, start: .instructions(instructions))
    }

    /// Runs one generation call as one job in the queue of the model. The
    /// first call loads the model first.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - channel: The channel that the events of the answer go into.
    /// - Throws: The error of the load, of
    ///   ``GenerationQueue/submit(isolation:_:)``, or of the model; or
    ///   ``PooledSessionError/notALanguageModel(key:containerType:)`` when the
    ///   container of the model is not a FoundationModels `LanguageModel`.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let loaded = try await resident.loaded()
        try await loaded.hold.queue.submit { [model = loaded.model] in
            try await model.respond(to: request, streamingInto: channel)
        }
    }

    /// Starts the load of the model, and then prewarms the loaded model. The
    /// call returns at once. A failed load is not reported here: the next
    /// generation call loads again and throws the error.
    ///
    /// - Parameter transcript: The transcript of the session.
    func prewarm(transcript: Transcript) {
        Task { [resident] in
            try? await resident.loaded().model.prewarm(transcript: transcript)
        }
    }
}

/// The executor of ``PooledModel``. It holds no state: each call gets the
/// pooled model, which holds the model of the pool.
public struct PooledModelExecutor: LanguageModelExecutor {
    /// The cache key that FoundationModels makes and reuses the executor by.
    public struct Configuration: Hashable, Sendable {
        /// The LLM.
        let key: ModelPoolKey
    }

    /// Makes an executor. The executor reads nothing from the configuration.
    ///
    /// - Parameter configuration: The cache key.
    public init(configuration: Configuration) {}

    /// Starts the load of the model, and then prewarms the loaded model. The
    /// call returns at once.
    ///
    /// - Parameters:
    ///   - model: The pooled model.
    ///   - transcript: The transcript of the session.
    public func prewarm(model: PooledModel, transcript: Transcript) {
        model.prewarm(transcript: transcript)
    }

    /// Runs one generation call as one job in the queue of the model.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - model: The pooled model.
    ///   - channel: The channel that the events of the answer go into.
    /// - Throws: The error of the load, of the queue, or of the model.
    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: PooledModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try await model.respond(to: request, streamingInto: channel)
    }
}

/// A hold of an LLM, and the executor of its container.
private struct LoadedLanguageModel: Sendable {
    /// The hold of the model.
    let hold: ModelHold
    /// The container of the hold, with its executor.
    let model: ExecutableLanguageModel

    /// Takes the container of `hold` as a FoundationModels `LanguageModel`,
    /// and makes its executor.
    ///
    /// - Parameter hold: A hold of an LLM.
    /// - Throws: ``PooledSessionError/notALanguageModel(key:containerType:)``
    ///   when the container of `hold` is not a FoundationModels
    ///   `LanguageModel`, or the error of the executor initializer.
    init(hold: ModelHold) throws {
        guard let languageModel = hold.container as? any LanguageModel else {
            throw PooledSessionError.notALanguageModel(
                key: hold.key, containerType: String(describing: type(of: hold.container)))
        }
        self.hold = hold
        self.model = try ExecutableLanguageModel(languageModel)
    }
}

/// A FoundationModels `LanguageModel` of any type, with one executor that
/// the calls share.
private struct ExecutableLanguageModel: Sendable {
    /// Runs one generation call on the model.
    private let respond: @Sendable (LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel)
        async throws -> Void

    /// Prewarms the model.
    private let prewarm: @Sendable (Transcript) -> Void

    /// Makes the executor of `model` from its configuration.
    ///
    /// - Parameter model: The model.
    /// - Throws: The error of the executor initializer.
    init<Model: LanguageModel>(_ model: Model) throws {
        let executor = try Model.Executor(configuration: model.executorConfiguration)
        respond = { request, channel in
            try await executor.respond(to: request, model: model, streamingInto: channel)
        }
        prewarm = { transcript in
            executor.prewarm(model: model, transcript: transcript)
        }
    }

    /// Runs one generation call on the model.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - channel: The channel that the events of the answer go into.
    /// - Throws: The error of the model.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try await respond(request, channel)
    }

    /// Prewarms the model.
    ///
    /// - Parameter transcript: The transcript of the session.
    func prewarm(transcript: Transcript) {
        prewarm(transcript)
    }
}
