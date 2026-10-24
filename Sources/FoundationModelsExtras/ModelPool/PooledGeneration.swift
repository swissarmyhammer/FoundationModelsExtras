import FoundationModels
import MLXFoundationModels
import Metrics
import Synchronization

/// One call into a local model, for one generation: the path of each pooled
/// call into an MLX model.
///
/// The rule of the design of 2026-10-24: a lock must not cross over a tool
/// call, only over the call into the model. The lock is the FIFO lock of the
/// `SerialAccessContainer` of MLX, which the model holds for one generation.
/// The SDK runs the tool bodies after the respond call of the executor
/// returns, thus no tool body runs under that lock. A cloud model multiplexes
/// its calls, thus it needs no lock.
///
/// The helper adds two things to the call:
///
/// - A meter of the calls in flight, `generate.in_flight`, by model. A call
///   counts from its start to its end, also while it waits for the lock.
/// - A cancel that does not wait for the lock. The lock of MLX waits with no
///   cancel handler. Thus the helper runs the call in its own task, and a
///   cancel of the caller cancels that task at once and throws
///   `CancellationError` to the caller at once. The abandoned call leaves the
///   lock at its turn, because it sees the cancel.
///
/// MLX checks the prompt cache of a session out before it takes the lock, and
/// checks it in after the call. An abandoned call that waits for the lock
/// thus holds the cache of its session. The next call of the same prompt
/// cache scope therefore waits until the abandoned call left, and then sees
/// the cache. A call of an other session never waits for it.
///
/// The helper opens no span: each caller keeps its own generate span.
///
/// ```swift
/// try await PooledGeneration.run(ref: ref, channel: channel) { modelChannel in
///     try await executor.respond(to: request, model: model, streamingInto: modelChannel)
/// }
/// ```
public enum PooledGeneration {
    /// The type of the events of a model.
    typealias Event = LanguageModelExecutorGenerationChannel.Event

    /// The prompt cache of one session of one model: the key of the last call
    /// of that session.
    private struct ScopeKey: Hashable {
        /// The model.
        let ref: ModelRef

        /// The id of the session, from a `.session` prompt cache scope.
        let session: String
    }

    /// The last call of one prompt cache scope.
    private struct LastCall {
        /// The id of the call, which tells it apart from a later call of the
        /// same scope.
        let id: Int

        /// The task of the call.
        let task: Task<Void, any Error>
    }

    /// The last calls of the prompt cache scopes, and the id of the next call.
    private struct Scopes {
        /// The last call of each scope that has a call that did not end.
        var lastCalls: [ScopeKey: LastCall] = [:]

        /// The id that the next call gets.
        var nextID = 0
    }

    /// The last call of each prompt cache scope. A new call of a scope waits
    /// until the last call ended. A call removes itself when it ends and no
    /// later call of its scope came.
    private static let scopes = Mutex(Scopes())

    /// Runs `body`, the one call into the model `ref` for one generation, and
    /// relays each event of the call into `channel`.
    ///
    /// The prompt cache scope of the call is `MLXLanguageModel.promptCacheScope`
    /// of the caller. `body` runs in a task that keeps the task-local values
    /// of the caller, thus the scope reaches the model.
    ///
    /// - Parameters:
    ///   - ref: The model of the call, for the in-flight meter.
    ///   - channel: The channel that the events of the call go into.
    ///   - body: The call into the model. It gets the channel that the model
    ///     sends its events into.
    /// - Throws: The error of `body`, or `CancellationError` at once when the
    ///   task of the caller is cancelled.
    public static func run(
        ref: ModelRef,
        channel: LanguageModelExecutorGenerationChannel,
        _ body: @escaping @Sendable (LanguageModelExecutorGenerationChannel) async throws -> Void
    ) async throws {
        try await run(ref: ref, cacheScope: MLXLanguageModel.promptCacheScope, channel: channel, body)
    }

    /// Runs `body` as ``run(ref:channel:_:)`` does, with the prompt cache
    /// scope `cacheScope`.
    ///
    /// - Parameters:
    ///   - ref: The model of the call, for the in-flight meter.
    ///   - cacheScope: The prompt cache scope of the call. A `.session` scope
    ///     makes the call wait for an abandoned call of the same session and
    ///     model. `nil` and `.uncached` wait for no other call.
    ///   - channel: The channel that the events of the call go into.
    ///   - body: The call into the model.
    /// - Throws: The error of `body`, or `CancellationError` at once when the
    ///   task of the caller is cancelled.
    static func run(
        ref: ModelRef,
        cacheScope: MLXLanguageModel.PromptCacheScope?,
        channel: LanguageModelExecutorGenerationChannel,
        _ body: @escaping @Sendable (LanguageModelExecutorGenerationChannel) async throws -> Void
    ) async throws {
        let inFlight = Meter(
            label: ExtrasTelemetry.MetricName.generateInFlight,
            dimensions: [(ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue)])
        inFlight.increment()
        defer { inFlight.decrement() }
        let (events, buffer) = AsyncStream.makeStream(of: Event.self)
        let call = startCall(of: ref, in: cacheScope) { try await relayCall(body, into: buffer) }
        try await withTaskCancellationHandler {
            for await event in events {
                try Task.checkCancellation()
                await channel.send(event)
            }
            try Task.checkCancellation()
            try await call.value
        } onCancel: {
            call.cancel()
            buffer.finish()
        }
    }

    /// Starts the task of one call. The task is a plain `Task`, not a
    /// detached task, thus it keeps the task-local values of the caller: the
    /// prompt cache scope of MLX, the metrics factory and the service context.
    ///
    /// A call of a `.session` scope first waits until the last call of the
    /// same session and model ended. A session runs one call at a time, thus
    /// that call ended already, unless its caller abandoned it while it
    /// waited for the lock of the model. Then the new call counts one wait on
    /// `generate.abandoned_waits`. A call that the caller cancelled before it
    /// ran does not run.
    ///
    /// - Parameters:
    ///   - ref: The model of the call.
    ///   - cacheScope: The prompt cache scope of the call.
    ///   - run: The call.
    /// - Returns: The task of the call.
    private static func startCall(
        of ref: ModelRef,
        in cacheScope: MLXLanguageModel.PromptCacheScope?,
        _ run: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, any Error> {
        guard case .session(let session) = cacheScope else {
            return Task { try await run() }
        }
        let key = ScopeKey(ref: ref, session: session)
        return scopes.withLock { scopes in
            let id = scopes.nextID
            scopes.nextID += 1
            let previous = scopes.lastCalls[key]?.task
            if previous != nil {
                Counter(
                    label: ExtrasTelemetry.MetricName.generateAbandonedWaits,
                    dimensions: [(ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue)]
                ).increment()
            }
            let task = Task {
                defer { endCall(id, of: key) }
                _ = await previous?.result
                try Task.checkCancellation()
                try await run()
            }
            scopes.lastCalls[key] = LastCall(id: id, task: task)
            return task
        }
    }

    /// Removes the call `id` from the last calls, when no later call of its
    /// scope came.
    ///
    /// - Parameters:
    ///   - id: The id of the call that ended.
    ///   - key: The scope of the call.
    private static func endCall(_ id: Int, of key: ScopeKey) {
        scopes.withLock { scopes in
            if scopes.lastCalls[key]?.id == id {
                scopes.lastCalls[key] = nil
            }
        }
    }

    /// Runs `body` with a new channel, and puts each event of that channel
    /// in `buffer`. Ends `buffer` when `body` returned and each of its events
    /// is in `buffer`.
    ///
    /// A generation channel is a rendezvous channel: a send returns only when
    /// a reader takes the event. The reader of the channel of `body` runs in
    /// a task of its own, not in a child task. Thus a cancel of the call does
    /// not stop the reader, and a model that still sends after the cancel
    /// never waits for a reader while it holds its lock.
    ///
    /// - Parameters:
    ///   - body: The call into the model.
    ///   - buffer: The stream that the caller relays into its channel.
    /// - Throws: The error of `body`.
    private static func relayCall(
        _ body: @Sendable (LanguageModelExecutorGenerationChannel) async throws -> Void,
        into buffer: AsyncStream<Event>.Continuation
    ) async throws {
        let modelChannel = LanguageModelExecutorGenerationChannel()
        let reader = Task {
            defer { buffer.finish() }
            do {
                for try await event in modelChannel {
                    buffer.yield(event)
                }
            } catch {
                // Only a failed channel throws, and nothing fails the new
                // channel of a call. The reader then reads no more.
            }
        }
        defer { reader.cancel() }
        try await body(modelChannel)
        reader.cancel()
        await reader.value
    }
}
