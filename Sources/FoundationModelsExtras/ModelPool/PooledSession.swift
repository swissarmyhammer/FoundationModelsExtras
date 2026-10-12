import Foundation
import FoundationModels

/// A FoundationModels session of a pooled LLM. A ``PooledModel`` makes it.
///
/// The session keeps one ``ModelHold``, so the model stays resident while the
/// session exists. Each respond call is one job in the queue of the hold, so
/// the calls of all sessions of one model run one at a time. Thus a tool that
/// the model calls in a respond call must not wait for a respond call of a
/// session of the same model: the queue refuses that call with
/// ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
///
/// ```swift
/// let session = try await qwen.session(instructions: "Answer in one word.")
/// let text = try await session.respond(to: "What color is the sky?")
/// let child = try await session.fork()   // continues the transcript, with its own hold
/// ```
public final class PooledSession: Sendable {
    /// The hold of the model.
    private let hold: ModelHold

    /// The pool of the hold. A fork acquires its own hold here.
    private let pool: ModelPool

    /// The tools that the model can call in the session. A fork gets the
    /// same tools.
    private let tools: [any Tool]

    /// The FoundationModels session over the model of the hold. Its model is
    /// a ``GenerateRelayModel``, thus each model round of a respond call goes
    /// through the generate call of that respond call.
    private let session: LanguageModelSession

    /// The generate call of the respond call that runs.
    private let generateCalls: GenerateCallSlot

    /// The Hugging Face name of the model.
    public var model: ModelRef { hold.key.ref }

    /// Makes a session over the model of `hold`.
    ///
    /// - Parameters:
    ///   - hold: A hold of an LLM of `pool`.
    ///   - pool: The pool of `hold`.
    ///   - tools: The tools that the model can call in the session.
    ///   - start: The instructions or the transcript that the session starts
    ///     with.
    /// - Throws: ``PooledSessionError/notALanguageModel(key:containerType:)``
    ///   when the container of `hold` is not a FoundationModels
    ///   `LanguageModel`, or the error of the executor initializer of the
    ///   container.
    init(hold: ModelHold, pool: ModelPool, tools: [any Tool], start: PooledSessionStart) throws {
        guard let languageModel = hold.container as? any LanguageModel else {
            throw PooledSessionError.notALanguageModel(
                key: hold.key, containerType: String(describing: type(of: hold.container)))
        }
        self.hold = hold
        self.pool = pool
        self.tools = tools
        let generateCalls = GenerateCallSlot()
        self.generateCalls = generateCalls
        let relayModel = try GenerateRelayModel(languageModel, slot: generateCalls)
        self.session = Self.makeSession(model: relayModel, tools: tools, start: start)
    }

    /// Answers `prompt`, and keeps the prompt and the answer in the
    /// transcript. The call waits in the queue of the model.
    ///
    /// - Parameter prompt: The prompt.
    /// - Returns: The text of the answer.
    /// - Throws: The error of ``GenerationQueue/submit(isolation:_:)`` or of
    ///   the model.
    public func respond(to prompt: String) async throws -> String {
        try await generate(guided: false) { session in
            try await session.respond(to: prompt).content
        }
    }

    /// Answers `prompt` with a value of `type`, and keeps the prompt and the
    /// answer in the transcript. The model generates with the schema of
    /// `type`. The call waits in the queue of the model.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - type: The type of the answer.
    /// - Returns: The answer.
    /// - Throws: The error of ``GenerationQueue/submit(isolation:_:)``, of the
    ///   model, or of the decode of the answer.
    public func respond<T: Generable>(to prompt: String, generating type: T.Type) async throws -> T {
        let schema = type.generationSchema
        let content = try await generate(guided: true) { session in
            try await session.respond(to: prompt, schema: schema).content
        }
        return try type.init(content)
    }

    /// Runs one respond call of the session as one job in the queue of the
    /// model, in one generate span of ``GenerateTelemetry``.
    ///
    /// The span opens before the wait in the queue. The session has its hold
    /// already, thus the call includes no load, and the span is not cold.
    /// Each tool that the model calls runs inside the respond call, thus each
    /// tool span is a child of the generate span.
    ///
    /// - Parameters:
    ///   - guided: Whether the respond call gives a generation schema to the
    ///     model.
    ///   - respond: The respond call on the FoundationModels session.
    /// - Returns: The value of `respond`.
    /// - Throws: The error of ``GenerationQueue/submit(isolation:_:)`` or of
    ///   `respond`.
    private func generate<Output: Sendable>(
        guided: Bool, _ respond: @escaping @Sendable (LanguageModelSession) async throws -> Output
    ) async throws -> Output {
        try await GenerateTelemetry.traceGenerate(of: model, guided: guided) { call in
            call.markCold(false)
            return try await hold.queue.submit { [session, generateCalls] in
                try await generateCalls.run(call) { try await respond(session) }
            }
        }
    }

    /// Makes a new session that continues the transcript of this session. The
    /// fork keeps its own hold of the model, and has the same tools. A later
    /// turn of one session does not change the transcript of the other.
    ///
    /// The fork reads the transcript as one job in the queue of the model, so
    /// it waits for a respond call that runs.
    ///
    /// - Returns: The fork.
    /// - Throws: The error of ``GenerationQueue/submit(isolation:_:)``.
    public func fork() async throws -> PooledSession {
        let transcript = try await hold.queue.submit { [session] in session.transcript }
        let forkHold = try await pool.acquire(hold.key)
        return try PooledSession(hold: forkHold, pool: pool, tools: tools, start: .transcript(transcript))
    }

    /// Makes the FoundationModels session of `model`.
    ///
    /// - Parameters:
    ///   - model: The LLM.
    ///   - tools: The tools that the model can call in the session.
    ///   - start: The instructions or the transcript that the session starts
    ///     with.
    /// - Returns: The session.
    private static func makeSession(
        model: any LanguageModel, tools: [any Tool], start: PooledSessionStart
    ) -> LanguageModelSession {
        switch start {
        case .instructions(let instructions):
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        case .transcript(let transcript):
            LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
    }
}

/// What a new ``PooledSession`` starts with.
enum PooledSessionStart {
    /// An empty transcript with these instructions, or with no instructions.
    case instructions(String?)
    /// The transcript of the session that the new session forks.
    case transcript(Transcript)
}

/// An error of ``PooledSession``.
public enum PooledSessionError: Error, Equatable, LocalizedError {
    /// The container of `key` has the type `containerType`, which is not a
    /// FoundationModels `LanguageModel`.
    case notALanguageModel(key: ModelPoolKey, containerType: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .notALanguageModel(let key, let containerType):
            return """
                The container of \(key.ref.stringValue) is a \(containerType), which is not a FoundationModels \
                LanguageModel. The first loader of a key gives the container of all holds, so each loader of \
                an LLM key must return a LanguageModel.
                """
        }
    }
}
