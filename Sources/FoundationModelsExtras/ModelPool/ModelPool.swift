import Synchronization

/// Loads each model one time, and shares it through holds.
///
/// Each load and each eviction runs as one job in one admission queue. Thus a
/// job that reads the footprint and then loads sees no other change of memory.
public final class ModelPool: Sendable {
    /// The pool of the process.
    public static let shared = ModelPool()

    /// One resident model.
    fileprivate struct Entry {
        let container: any Sendable
        let loader: any PooledModelLoader
        /// The one work queue of the model. All holds of the key share it.
        let queue = GenerationQueue()
        /// The weights, and the session of each hold.
        var bytes: Int64
        var holds = 1
    }

    /// All the state of the pool.
    private struct State {
        var entries: [ModelPoolKey: Entry] = [:]
        var loadingBytes: Int64 = 0
        var streams: [Int: AsyncStream<ModelPoolFootprint>.Continuation] = [:]
        var lastStreamID = 0

        var footprint: ModelPoolFootprint {
            ModelPoolFootprint(resident: entries.mapValues(\.bytes), loadingBytes: loadingBytes)
        }

        /// Sends the footprint to each stream. Each change calls this under the
        /// lock, so each stream sees the changes in order.
        func publish() {
            for stream in streams.values {
                stream.yield(footprint)
            }
        }
    }

    /// The state, under one lock.
    private let state = Mutex(State())

    /// The queue of the loads and the evictions.
    let admissions = GenerationQueue()

    /// Makes an empty pool.
    public init() {}

    /// Gives a hold of the model of `key`. A resident key adds a hold at once.
    /// A new key loads in the admission queue. `footprintBytes` is the weights
    /// and one session; `sessionBytes` is the session of this hold.
    ///
    /// The first loader of a key wins: a later caller gets that container,
    /// whatever loader it gives. Thus use the container through a protocol,
    /// never by a cast to the container type of one loader.
    public func acquire(
        _ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64, loader: any PooledModelLoader
    ) async throws -> ModelHold {
        if let hold = holdIfResident(key, sessionBytes: sessionBytes) { return hold }
        return try await admit { admission in
            try await admission.acquire(key, footprintBytes: footprintBytes, sessionBytes: sessionBytes, loader: loader)
        }
    }

    /// Runs `job` as one admission job. Inside `job`, acquire through the
    /// admission: ``acquire(_:footprintBytes:sessionBytes:loader:)`` of the
    /// pool waits for the end of this job.
    public func admit<T: Sendable>(
        _ job: @escaping @Sendable (ModelPoolAdmission) async throws -> T
    ) async throws -> T {
        try await admissions.submit { try await job(ModelPoolAdmission(pool: self)) }
    }

    /// The memory that the models use now.
    public var footprint: ModelPoolFootprint { state.withLock { $0.footprint } }

    /// The current footprint first, then each change. Each call makes a new stream.
    public var footprints: AsyncStream<ModelPoolFootprint> {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelPoolFootprint.self)
        let id = state.withLock { state in
            continuation.yield(state.footprint)
            state.lastStreamID += 1
            state.streams[state.lastStreamID] = continuation
            return state.lastStreamID
        }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.streams[id] = nil } }
        return stream
    }

    /// The number of resident models.
    public var residentModelCount: Int { state.withLock { $0.entries.count } }

    /// Whether the model of `key` is resident.
    public func isResident(_ key: ModelPoolKey) -> Bool { state.withLock { $0.entries[key] != nil } }

    /// Adds a hold when `key` is resident.
    fileprivate func holdIfResident(_ key: ModelPoolKey, sessionBytes: Int64) -> ModelHold? {
        state.withLock { state in
            guard let entry = state.entries[key] else { return nil }
            state.entries[key]?.holds += 1
            state.entries[key]?.bytes += sessionBytes
            state.publish()
            return ModelHold(pool: self, key: key, entry: entry, sessionBytes: sessionBytes)
        }
    }

    /// Loads `key` in the running admission job, and gives its first hold.
    fileprivate func load(
        _ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64, loader: any PooledModelLoader
    ) async throws -> ModelHold {
        setLoadingBytes(footprintBytes)
        let container: any Sendable
        do {
            container = try await loader.load(key)
        } catch {
            setLoadingBytes(0)
            throw error
        }
        let entry = Entry(container: container, loader: loader, bytes: footprintBytes)
        state.withLock { state in
            state.loadingBytes = 0
            state.entries[key] = entry
            state.publish()
        }
        return ModelHold(pool: self, key: key, entry: entry, sessionBytes: sessionBytes)
    }

    /// Sets the bytes of the load that runs now.
    private func setLoadingBytes(_ bytes: Int64) {
        state.withLock { state in
            state.loadingBytes = bytes
            state.publish()
        }
    }

    /// Removes one hold. The last hold puts an eviction job in the admission
    /// queue in the same step, so each admission job after it runs after the
    /// eviction job.
    fileprivate func release(_ key: ModelPoolKey, sessionBytes: Int64) {
        // Lock order: the pool lock, then the queue lock. No queue code
        // takes the pool lock.
        state.withLock { state in
            state.entries[key]?.holds -= 1
            state.entries[key]?.bytes -= sessionBytes
            state.publish()
            guard state.entries[key]?.holds == 0 else { return }
            admissions.enqueue { await self.evictIfIdle(key) }
        }
    }

    /// The eviction job: evicts the model of `key` when it still has no hold.
    private func evictIfIdle(_ key: ModelPoolKey) async {
        let idle = state.withLock { state in
            state.entries[key]?.holds == 0 ? state.entries.removeValue(forKey: key) : nil
        }
        guard let idle else { return }
        await idle.loader.evict(idle.container)
        state.withLock { $0.publish() }
    }
}

/// The pool inside one admission job. Use it only inside that job.
public struct ModelPoolAdmission: Sendable {
    /// The pool of the job.
    fileprivate let pool: ModelPool

    /// The memory that the models use now.
    public var footprint: ModelPoolFootprint { pool.footprint }

    /// Gives a hold of the model of `key`, and loads the model now when it is
    /// not resident. See ``ModelPool/acquire(_:footprintBytes:sessionBytes:loader:)``.
    public func acquire(
        _ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64, loader: any PooledModelLoader
    ) async throws -> ModelHold {
        if let hold = pool.holdIfResident(key, sessionBytes: sessionBytes) { return hold }
        return try await pool.load(key, footprintBytes: footprintBytes, sessionBytes: sessionBytes, loader: loader)
    }
}

/// One use of a resident model. The model stays resident while a hold exists.
public final class ModelHold: Sendable {
    /// The model.
    public let key: ModelPoolKey
    /// The container that the first loader of the key returned.
    public let container: any Sendable
    /// The one work queue of the model. All holds of the key share it.
    public let queue: GenerationQueue
    /// The pool that counts this hold.
    private let pool: ModelPool
    /// The bytes of the session of this hold.
    private let sessionBytes: Int64

    /// Makes a hold of `entry` that `pool` counts already.
    fileprivate init(pool: ModelPool, key: ModelPoolKey, entry: ModelPool.Entry, sessionBytes: Int64) {
        self.pool = pool
        self.key = key
        self.container = entry.container
        self.queue = entry.queue
        self.sessionBytes = sessionBytes
    }

    /// Releases the hold.
    deinit { pool.release(key, sessionBytes: sessionBytes) }
}
