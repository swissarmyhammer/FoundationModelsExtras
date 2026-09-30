import FoundationModels

/// An LLM of a ``ModelPool``, by its Hugging Face name. A pooled model loads
/// nothing when you make it. Each ``session(instructions:tools:)`` call
/// acquires the model from the pool: the pool loads the model one time, and
/// gives one hold to each session.
///
/// ```swift
/// let qwen = PooledModel(ref: "mlx-community/Qwen3-4B-4bit")   // loads nothing
/// let session = try await qwen.session(instructions: "Answer in one word.")
/// let text = try await session.respond(to: "What color is the sky?")
/// ```
public struct PooledModel: Sendable {
    /// The pool that loads the model.
    private let pool: ModelPool

    /// The LLM.
    private let key: ModelPoolKey

    /// Makes a model of the LLM `ref`. This loads nothing: the first
    /// ``session(instructions:tools:)`` call loads the model into `pool`.
    ///
    /// - Parameters:
    ///   - ref: The Hugging Face name of the LLM.
    ///   - pool: The pool that loads the model with its loader. The default is
    ///     ``ModelPool/shared``.
    public init(ref: ModelRef, pool: ModelPool = .shared) {
        self.pool = pool
        self.key = ModelPoolKey(ref: ref, role: .llm)
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
}
