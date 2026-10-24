import FoundationModels
import Synchronization

/// The generate call of the respond call that runs on one ``PooledSession``.
///
/// One `LanguageModelSession` runs one respond call at a time: it refuses a
/// second call that comes while one runs, with
/// `LanguageModelSession.Error.concurrentRequests`. Each ``PooledSession``
/// has one `LanguageModelSession` and one slot, thus the slot holds one call
/// at most.
final class GenerateCallSlot: Sendable {
    /// The call that runs, or `nil` between the respond calls.
    private let running = Mutex<GenerateCall?>(nil)

    /// The call that runs now, or `nil` between the respond calls.
    var current: GenerateCall? { running.withLock { $0 } }

    /// Runs `body` with `call` as the current call, and then empties the
    /// slot.
    ///
    /// - Parameters:
    ///   - call: The recorder of the respond call.
    ///   - body: The respond call.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    func run<Output>(_ call: GenerateCall, _ body: () async throws -> Output) async throws -> Output {
        running.withLock { $0 = call }
        defer { running.withLock { $0 = nil } }
        return try await body()
    }
}

/// The model of the FoundationModels session of a ``PooledSession``: the
/// container model of the hold, whose events go through the generate call
/// of the respond call that runs.
///
/// Each executor call of the session is one model round of that call. Thus
/// the generate call sees the first event and the token counts of each
/// round.
struct GenerateRelayModel: LanguageModel {
    /// The executor that relays each model round.
    typealias Executor = GenerateRelayExecutor

    /// The container model, with its executor.
    fileprivate let model: ExecutableLanguageModel

    /// The Hugging Face name of the container model, for the in-flight meter
    /// of each model round.
    fileprivate let ref: ModelRef

    /// The generate call of the respond call that runs.
    fileprivate let slot: GenerateCallSlot

    /// What the container model can do.
    let capabilities: LanguageModelCapabilities

    /// The cache key of the executor. The key is the same for each session,
    /// because the executor holds no state.
    var executorConfiguration: GenerateRelayExecutor.Configuration {
        GenerateRelayExecutor.Configuration()
    }

    /// Makes the model of a session over `model`.
    ///
    /// - Parameters:
    ///   - model: The container model of the hold of the session.
    ///   - ref: The Hugging Face name of the container model.
    ///   - slot: The generate call of the respond call that runs.
    /// - Throws: The error of the executor initializer of `model`.
    init(_ model: any LanguageModel, ref: ModelRef, slot: GenerateCallSlot) throws {
        self.model = try ExecutableLanguageModel(model)
        self.ref = ref
        self.slot = slot
        self.capabilities = model.capabilities
    }
}

/// The executor of ``GenerateRelayModel``.
struct GenerateRelayExecutor: LanguageModelExecutor {
    /// The cache key that FoundationModels makes and reuses the executor by.
    ///
    /// The key has no field. The executor holds no state, because the model
    /// and its slot arrive with each call. Thus one executor can serve each
    /// session.
    struct Configuration: Hashable, Sendable {}

    /// Makes an executor. The executor reads nothing from the configuration:
    /// the model arrives with each call.
    ///
    /// - Parameter configuration: The cache key.
    init(configuration: Configuration) {}

    /// Prewarms the container model.
    ///
    /// - Parameters:
    ///   - model: The model of the session.
    ///   - transcript: The transcript of the session.
    func prewarm(model: GenerateRelayModel, transcript: Transcript) {
        model.model.prewarm(transcript: transcript)
    }

    /// Runs one model round on the container model through
    /// ``PooledGeneration``. Thus the round waits only for the lock that the
    /// model holds for one generation, and the tool bodies of the session
    /// run outside it. The events go through the generate call of the
    /// respond call that runs. A round outside a respond call goes straight
    /// to `channel`: no generate call records it.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - model: The model of the session.
    ///   - channel: The channel that the events of the answer go into.
    /// - Throws: The error of the container model, or `CancellationError`
    ///   when the task is cancelled.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: GenerateRelayModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        guard let call = model.slot.current else {
            try await Self.generate(request, on: model, into: channel)
            return
        }
        try await call.relay(into: channel) { modelChannel in
            try await Self.generate(request, on: model, into: modelChannel)
        }
    }

    /// Runs one model round on the container model of `model` through
    /// ``PooledGeneration``.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - model: The model of the session.
    ///   - channel: The channel that the events of the round go into.
    /// - Throws: The error of the container model, or `CancellationError`
    ///   when the task is cancelled.
    private static func generate(
        _ request: LanguageModelExecutorGenerationRequest,
        on model: GenerateRelayModel,
        into channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try await PooledGeneration.run(
            ref: model.ref, cacheScope: PooledGeneration.cacheScope(of: request), channel: channel
        ) { [container = model.model] generationChannel in
            try await container.respond(to: request, streamingInto: generationChannel)
        }
    }
}
