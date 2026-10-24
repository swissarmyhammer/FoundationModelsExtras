import Foundation
import FoundationModels

/// A FoundationModels session of a pooled LLM. A ``PooledModel`` makes it.
///
/// The session keeps one ``ModelHold``, so the model stays resident while the
/// session exists. Only the call into the model waits: each model round of a
/// respond call goes through ``PooledGeneration``, and the model holds its own
/// lock for one generation, as MLX does. The SDK runs each tool body between
/// two model rounds, outside each lock. Thus a tool that the model calls can
/// use a respond call of a session of the same model, and the sessions of one
/// model take turns for each generation, not for each whole respond call.
///
/// ```swift
/// let session = try await qwen.session(instructions: "Answer in one word.")
/// let text = try await session.respond(to: "What color is the sky?")
/// ```
public final class PooledSession: Sendable {
    /// The hold of the model.
    private let hold: ModelHold

    /// The FoundationModels session over the model of the hold. Its model is
    /// a ``GenerateRelayModel``, thus each model round of a respond call goes
    /// through the generate call of that respond call.
    private let session: LanguageModelSession

    /// The generate call of the respond call that runs.
    private let generateCalls: GenerateCallSlot

    /// The Hugging Face name of the model.
    public var model: ModelRef { hold.key.ref }

    /// Makes a session over the model of `hold`, with an empty transcript.
    ///
    /// - Parameters:
    ///   - hold: A hold of an LLM.
    ///   - tools: The tools that the model can call in the session.
    ///   - instructions: The instructions of the session, or `nil` for none.
    /// - Throws: ``PooledSessionError/notALanguageModel(key:containerType:)``
    ///   when the container of `hold` is not a FoundationModels
    ///   `LanguageModel`, or the error of the executor initializer of the
    ///   container.
    init(hold: ModelHold, tools: [any Tool], instructions: String?) throws {
        guard let languageModel = hold.container as? any LanguageModel else {
            throw PooledSessionError.notALanguageModel(
                key: hold.key, containerType: String(describing: type(of: hold.container)))
        }
        self.hold = hold
        let generateCalls = GenerateCallSlot()
        self.generateCalls = generateCalls
        let relayModel = try GenerateRelayModel(languageModel, ref: hold.key.ref, slot: generateCalls)
        self.session = LanguageModelSession(model: relayModel, tools: tools, instructions: instructions)
    }

    /// Answers `prompt`, and keeps the prompt and the answer in the
    /// transcript. Each model round of the call waits only for the lock of
    /// the model.
    ///
    /// - Parameter prompt: The prompt.
    /// - Returns: The text of the answer.
    /// - Throws: The error of the model, or `CancellationError` when the task
    ///   is cancelled.
    public func respond(to prompt: String) async throws -> String {
        try await generate(guided: false) { session in
            try await session.respond(to: prompt).content
        }
    }

    /// Answers `prompt` with a value of `type`, and keeps the prompt and the
    /// answer in the transcript. The model generates with the schema of
    /// `type`. Each model round of the call waits only for the lock of the
    /// model.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - type: The type of the answer.
    /// - Returns: The answer.
    /// - Throws: The error of the model or of the decode of the answer, or
    ///   `CancellationError` when the task is cancelled.
    public func respond<T: Generable>(to prompt: String, generating type: T.Type) async throws -> T {
        let schema = type.generationSchema
        let content = try await generate(guided: true) { session in
            try await session.respond(to: prompt, schema: schema).content
        }
        return try type.init(content)
    }

    /// Runs one respond call of the session on the task of the caller, in one
    /// generate span of ``GenerateTelemetry``.
    ///
    /// The session has its hold already, thus the call includes no load, and
    /// the span is not cold. Each tool that the model calls runs inside the
    /// respond call, thus each tool span is a child of the generate span.
    ///
    /// - Parameters:
    ///   - guided: Whether the respond call gives a generation schema to the
    ///     model.
    ///   - respond: The respond call on the FoundationModels session.
    /// - Returns: The value of `respond`.
    /// - Throws: The error of `respond`.
    private func generate<Output: Sendable>(
        guided: Bool, _ respond: @escaping @Sendable (LanguageModelSession) async throws -> Output
    ) async throws -> Output {
        try await GenerateTelemetry.traceGenerate(of: model, guided: guided) { call in
            call.markCold(false)
            return try await generateCalls.run(call) { try await respond(session) }
        }
    }
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
