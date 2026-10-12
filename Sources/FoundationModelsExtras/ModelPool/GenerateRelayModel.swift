import FoundationModels
import Synchronization

/// The generate call of the respond call that runs on one ``PooledSession``.
///
/// The respond calls of one session run one at a time, as jobs in the queue
/// of the model, thus the slot holds one call at most.
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

    /// The generate call of the respond call that runs.
    fileprivate let slot: GenerateCallSlot

    /// What the container model can do.
    let capabilities: LanguageModelCapabilities

    /// The cache key of the executor: the identity of the slot of the
    /// session.
    var executorConfiguration: GenerateRelayExecutor.Configuration {
        GenerateRelayExecutor.Configuration(slot: ObjectIdentifier(slot))
    }

    /// Makes the model of a session over `model`.
    ///
    /// - Parameters:
    ///   - model: The container model of the hold of the session.
    ///   - slot: The generate call of the respond call that runs.
    /// - Throws: The error of the executor initializer of `model`.
    init(_ model: any LanguageModel, slot: GenerateCallSlot) throws {
        self.model = try ExecutableLanguageModel(model)
        self.slot = slot
        self.capabilities = model.capabilities
    }
}

/// The executor of ``GenerateRelayModel``.
struct GenerateRelayExecutor: LanguageModelExecutor {
    /// The cache key that FoundationModels makes and reuses the executor by.
    struct Configuration: Hashable, Sendable {
        /// The identity of the slot of the session.
        let slot: ObjectIdentifier
    }

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

    /// Runs one model round on the container model. The events go through
    /// the generate call of the respond call that runs. A round outside a
    /// respond call goes straight to `channel`: no generate call records it.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - model: The model of the session.
    ///   - channel: The channel that the events of the answer go into.
    /// - Throws: The error of the container model.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: GenerateRelayModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        guard let call = model.slot.current else {
            try await model.model.respond(to: request, streamingInto: channel)
            return
        }
        try await call.relay(into: channel) { modelChannel in
            try await model.model.respond(to: request, streamingInto: modelChannel)
        }
    }
}
