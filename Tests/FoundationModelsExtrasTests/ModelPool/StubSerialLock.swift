import Foundation
import FoundationModels
import MLXFoundationModels
import Synchronization

/// A lock of one holder that gives the lock to its waiters in FIFO order, in
/// the shape of the `AsyncMutex` of the `SerialAccessContainer` of MLX.
///
/// A waiter waits with no cancel handler, as in MLX. Thus a cancelled waiter
/// gets the lock at its turn, and only then sees its cancel.
final class StubSerialLock: Sendable {
    /// The holder and the waiters of the lock.
    private struct State {
        /// Whether a caller holds the lock.
        var held = false

        /// Each caller that waits for the lock, in the order of the waits.
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// The holder and the waiters of the lock.
    private let state = Mutex(State())

    /// The name of each caller that waited for the lock, in the order of
    /// the waits. A caller that got the lock at once is not in it.
    let queued = Recorder<String>()

    /// Runs `body` while the caller holds the lock. A caller waits until each
    /// earlier caller released the lock.
    ///
    /// - Parameters:
    ///   - name: The name of the caller, which ``queued`` records when the
    ///     caller waits.
    ///   - body: The work that needs the lock.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    func withLock<Output>(_ name: String, _ body: () async throws -> Output) async rethrows -> Output {
        await acquire(name)
        defer { release() }
        return try await body()
    }

    /// Takes the lock, or waits at the end of the line until the lock comes.
    ///
    /// - Parameter name: The name of the caller.
    private func acquire(_ name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state -> Bool in
                guard state.held else {
                    state.held = true
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if acquired {
                continuation.resume()
            } else {
                queued.append(name)
            }
        }
    }

    /// Gives the lock to the first waiter, or frees the lock when no caller
    /// waits.
    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.held = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// The prompt caches of the sessions of a stub model, in the shape of the
/// prompt cache store of MLX: a call checks the cache of its session out
/// before it takes the lock of the model, and checks it back in after the
/// call. A check-in replaces the cache of the session.
///
/// A cache here is the list of the names of the calls that it holds. Each
/// check-out writes `"checkout <caller> <names>"` to the log, or
/// `"checkout <caller> cold"` when the store holds no cache for the session.
final class StubPromptCache: Sendable {
    /// The cache of each session, by the id of the session.
    private let caches = Mutex<[String: [String]]>([:])

    /// The log that gets each check-out.
    private let log: Recorder<String>

    /// Makes an empty store.
    ///
    /// - Parameter log: The log that gets each check-out.
    init(log: Recorder<String>) {
        self.log = log
    }

    /// Takes the cache of `session` out of the store.
    ///
    /// - Parameters:
    ///   - session: The id of the session.
    ///   - caller: The name of the call, for the log.
    /// - Returns: The cache, or `nil` when the store holds none.
    func checkOut(_ session: String, by caller: String) -> [String]? {
        let cache = caches.withLock { $0.removeValue(forKey: session) }
        log.append("checkout \(caller) \(cache?.joined(separator: ",") ?? "cold")")
        return cache
    }

    /// Puts `cache` in the store as the cache of `session`.
    ///
    /// - Parameters:
    ///   - session: The id of the session.
    ///   - cache: The cache.
    func checkIn(_ session: String, _ cache: [String]) {
        caches.withLock { $0[session] = cache }
    }
}

/// One generation of a stub model, in the shape of the respond call of MLX.
///
/// The call reads its session from `MLXLanguageModel.promptCacheScope`,
/// checks the cache of the session out, and waits for the lock. A call that
/// sees its cancel when the lock comes checks the cache back in unchanged,
/// writes `"leave <name>"`, and throws `CancellationError`. Else it writes
/// `"begin <name>"`, sends one text event with its name, waits until
/// `mayEnd` finishes, writes `"end <name>"`, and checks in the cache with its
/// name added.
struct StubGenerator: Sendable {
    /// The lock that each generation holds.
    let lock: StubSerialLock

    /// The prompt caches of the sessions.
    let cache: StubPromptCache

    /// The log of the generations and of the check-outs.
    let log: Recorder<String>

    /// The text that starts each session id of this generator. The calls of
    /// one session of one model wait for each other in each process, and
    /// the tests run in parallel, thus each generator has sessions of its own.
    let sessionPrefix = UUID().uuidString

    /// Makes a generator with a new lock, a new cache store and a new log.
    init() {
        let log = Recorder<String>()
        self.log = log
        self.lock = StubSerialLock()
        self.cache = StubPromptCache(log: log)
    }

    /// Runs one generation.
    ///
    /// - Parameters:
    ///   - name: The name of the generation.
    ///   - channel: The channel that the text event goes into.
    ///   - mayEnd: The generation ends only after this stream finishes.
    /// - Throws: `CancellationError` when the call sees its cancel when the
    ///   lock comes.
    func generate(
        _ name: String, into channel: LanguageModelExecutorGenerationChannel, mayEnd: AsyncStream<Void>
    ) async throws {
        let session = Self.session(of: MLXLanguageModel.promptCacheScope)
        let checkedOut = session.flatMap { cache.checkOut($0, by: name) } ?? []
        try await lock.withLock(name) {
            guard !Task.isCancelled else {
                if let session {
                    cache.checkIn(session, checkedOut)
                }
                log.append("leave \(name)")
                throw CancellationError()
            }
            log.append("begin \(name)")
            await channel.send(StubEvents.text(name))
            for await _ in mayEnd {}
            log.append("end \(name)")
            if let session {
                cache.checkIn(session, checkedOut + [name])
            }
        }
    }

    /// The session id of `scope`.
    ///
    /// - Parameter scope: The prompt cache scope of the task.
    /// - Returns: The id of a `.session` scope, else `nil`.
    private static func session(of scope: MLXLanguageModel.PromptCacheScope?) -> String? {
        guard case .session(let id) = scope else { return nil }
        return id
    }
}

/// The events that the stub generations send.
enum StubEvents {
    /// The token count of one text event. The stub meters nothing.
    private static let tokenCount = 1

    /// One event that appends `text` to the answer.
    ///
    /// - Parameter text: The text.
    /// - Returns: The event.
    static func text(_ text: String) -> LanguageModelExecutorGenerationChannel.Event {
        .response(action: .appendText(text, tokenCount: tokenCount))
    }

    /// Reads each event of `channel` into a new recorder, as the text of its
    /// description, until the task of the reader is cancelled.
    ///
    /// - Parameter channel: The channel to read.
    /// - Returns: The recorder, and the task of the reader.
    static func read(_ channel: LanguageModelExecutorGenerationChannel) -> (Recorder<String>, Task<Void, Never>) {
        let events = Recorder<String>()
        let reader = Task {
            do {
                for try await event in channel {
                    events.append(String(describing: event))
                }
            } catch {
                // Nothing fails a new channel. The reader then reads no more.
            }
        }
        return (events, reader)
    }
}
