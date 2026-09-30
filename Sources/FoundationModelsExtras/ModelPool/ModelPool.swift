import Foundation
import Synchronization

/// Loads each model one time, and shares it through holds.
///
/// Each load and each eviction runs as one job in one admission queue. Thus a
/// job that reads the footprint and then loads sees no other change of memory.
public final class ModelPool: Sendable {
    /// The pool of the process. It loads with ``MLXModelLoader``.
    public static let shared = ModelPool()

    /// An acquire by key counts no session bytes: the loader measures the
    /// model, and the model only.
    fileprivate static let measuredSessionBytes: Int64 = 0

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

    /// The input end of one footprint stream.
    private typealias FootprintContinuation = AsyncStream<ModelPoolFootprint>.Continuation

    /// All the state of the pool.
    private struct State {
        /// The models that can give holds.
        var entries: [ModelPoolKey: Entry] = [:]
        /// The bytes of each model whose evict call runs now. The model uses
        /// its memory until that call returns, but it gives no more holds.
        var evicting: [ModelPoolKey: Int64] = [:]
        var loadingBytes: Int64 = 0
        var streams: [Int: FootprintContinuation] = [:]
        var lastStreamID = 0
        /// The progress streams of each model, and the loads that run now.
        var progress = ModelLoadProgressBoard()

        var footprint: ModelPoolFootprint {
            let resident = entries.mapValues(\.bytes).merging(evicting) { held, _ in held }
            return ModelPoolFootprint(resident: resident, loadingBytes: loadingBytes)
        }

        /// The number of models that use memory now.
        var residentCount: Int { entries.count + evicting.count }

        /// Whether the model of `key` uses memory now.
        func isResident(_ key: ModelPoolKey) -> Bool { entries[key] != nil || evicting[key] != nil }

        /// Whether a model of `ref`, in any role, gives holds now.
        func hasReadyModel(of ref: ModelRef) -> Bool { entries.keys.contains { $0.ref == ref } }

        /// A copy of each live stream, to yield to after the state lock.
        var liveStreams: [FootprintContinuation] { Array(streams.values) }
    }

    /// The state, under one lock. The termination handler of a footprint
    /// stream or of a progress stream takes only this lock. No code yields to
    /// a stream, or finishes a stream, while it holds this lock.
    private let state = Mutex(State())

    /// The publish lock. Each change that the streams see takes this lock,
    /// then the state lock. It yields the new footprint, or the new progress,
    /// after it releases the state lock, and before it releases this lock.
    /// Thus each stream sees the changes in the order that they occurred, and
    /// no value is lost.
    ///
    /// Lock order: this lock, then the state lock. No code takes this lock
    /// while it holds the state lock, and no termination handler takes this
    /// lock. Thus a yield that waits for a consumer task, while the runtime
    /// cancels that task and runs its termination handler, cannot deadlock.
    private let publishing = Mutex(())

    /// The queue of the loads and the evictions.
    let admissions = GenerationQueue()

    /// The loader of ``acquire(_:)``.
    public let loader: any PooledModelLoader

    /// Makes an empty pool.
    ///
    /// - Parameter loader: The loader of ``acquire(_:)``. The default is
    ///   ``MLXModelLoader``, which loads a model from its Hugging Face name.
    public init(loader: any PooledModelLoader = MLXModelLoader()) {
        self.loader = loader
    }

    /// Gives a hold of the model of `key`. A resident key adds a hold at once.
    /// A new key loads in the admission queue with ``loader``, which then
    /// measures the footprint of the model. The pool counts that footprint.
    ///
    /// The first loader of a key wins, as in
    /// ``acquire(_:footprintBytes:sessionBytes:loader:)``.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: A hold of the model. The model stays resident while the hold
    ///   exists.
    /// - Throws: The error of the load or of the measure. When the measure
    ///   fails, the loader evicts the model, and the key is not resident.
    public func acquire(_ key: ModelPoolKey) async throws -> ModelHold {
        if let hold = holdIfResident(key, sessionBytes: Self.measuredSessionBytes) { return hold }
        return try await admit { admission in try await admission.acquire(key) }
    }

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

    /// The memory that the models use now. The pool counts an evicted model
    /// until the evict call of its loader returns, because the model uses its
    /// memory until then.
    public var footprint: ModelPoolFootprint { state.withLock { $0.footprint } }

    /// The current footprint first, then each change. Each call makes a new
    /// stream. An evicted model stays in each value until the evict call of
    /// its loader returns, as in ``footprint``.
    public var footprints: AsyncStream<ModelPoolFootprint> {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelPoolFootprint.self)
        // The stream registers and gets its first value in one publish step.
        // Thus no later change comes before its first value.
        let id = publish { state in
            state.lastStreamID += 1
            state.streams[state.lastStreamID] = continuation
            return (state.lastStreamID, [continuation])
        }
        // Takes only the state lock: see ``publishing``.
        continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.streams[id] = nil } }
        return stream
    }

    /// The progress of the next load of `ref`, or of the load of `ref` that
    /// runs now. Each call makes a new stream.
    ///
    /// The stream gives zero or more
    /// ``ModelLoadProgress/downloading(completedBytes:totalBytes:)`` values,
    /// then ``ModelLoadProgress/loading``, then ``ModelLoadProgress/ready`` or
    /// ``ModelLoadProgress/failed(_:)``, and then ends. Each load gives its
    /// progress here, whatever acquire method and loader started it: the pool
    /// gives the progress handler of the stream to the loader of each load.
    /// All streams of one load get the same values. A stream that
    /// starts during a load gets the last value of that load first. A stream
    /// that starts when a model of `ref` is resident, and no load of `ref`
    /// runs, gives ``ModelLoadProgress/ready`` and ends.
    ///
    /// - Parameter ref: The model. A load of `ref` in any role counts.
    /// - Returns: A new stream of the progress of one load.
    public func progress(for ref: ModelRef) -> AsyncStream<ModelLoadProgress> {
        let (stream, observer) = AsyncStream.makeStream(of: ModelLoadProgress.self)
        // The stream registers and gets its first value in one publish step.
        // Thus no later value of the load comes before it.
        let id = deliverProgress { state in
            let added = state.progress.add(observer: observer, of: ref, isReady: state.hasReadyModel(of: ref))
            return (added.id, added.delivery)
        }
        if let id {
            // Takes only the state lock: see ``publishing``.
            observer.onTermination = { [weak self] _ in
                self?.state.withLock { $0.progress.removeObserver(id: id, of: ref) }
            }
        }
        return stream
    }

    /// The number of resident models. A model is resident until the evict
    /// call of its loader returns.
    public var residentModelCount: Int { state.withLock { $0.residentCount } }

    /// Whether the model of `key` is resident. A model is resident until the
    /// evict call of its loader returns. While that call runs, the model gives
    /// no hold: an acquire of `key` loads the model again after the eviction.
    public func isResident(_ key: ModelPoolKey) -> Bool { state.withLock { $0.isResident(key) } }

    /// Adds a hold when `key` is resident and not in its evict call.
    fileprivate func holdIfResident(_ key: ModelPoolKey, sessionBytes: Int64) -> ModelHold? {
        publish { state in
            guard let entry = state.entries[key] else { return (nil, []) }
            state.entries[key]?.holds += 1
            state.entries[key]?.bytes += sessionBytes
            return (ModelHold(pool: self, key: key, entry: entry, sessionBytes: sessionBytes), state.liveStreams)
        }
    }

    /// Loads `key` in the running admission job, and gives its first hold.
    /// The progress streams of the model see the load.
    fileprivate func load(
        _ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64, loader: any PooledModelLoader
    ) async throws -> ModelHold {
        try await reportingProgress(of: key.ref) { progressHandler in
            setLoadingBytes(footprintBytes)
            let container: any Sendable
            do {
                container = try await loader.load(key: key, progressHandler: progressHandler)
            } catch {
                setLoadingBytes(0)
                throw error
            }
            return makeResident(
                key, container: container, loader: loader, bytes: footprintBytes, sessionBytes: sessionBytes)
        }
    }

    /// Loads `key` with ``loader`` in the running admission job, measures its
    /// footprint, and gives its first hold. When the measure fails, the loader
    /// evicts the model. The progress streams of the model see the load.
    fileprivate func loadMeasured(_ key: ModelPoolKey) async throws -> ModelHold {
        try await reportingProgress(of: key.ref) { progressHandler in
            let container = try await loader.load(key: key, progressHandler: progressHandler)
            let bytes: Int64
            do {
                bytes = try await loader.footprintBytes(of: key)
            } catch {
                await loader.evict(container)
                throw error
            }
            return makeResident(
                key, container: container, loader: loader, bytes: bytes, sessionBytes: Self.measuredSessionBytes)
        }
    }

    /// Runs `load` as one load of `ref` that the progress streams of `ref`
    /// see. `load` gives its progress handler to the loader. The load ends
    /// with ``ModelLoadProgress/ready`` when `load` returns, after the model
    /// is resident, or with ``ModelLoadProgress/failed(_:)`` when it throws.
    ///
    /// - Parameters:
    ///   - ref: The model.
    ///   - load: Loads the model with the progress handler that it gets, and
    ///     gives the first hold.
    /// - Returns: The hold that `load` gives.
    /// - Throws: The error of `load`.
    private func reportingProgress(
        of ref: ModelRef,
        _ load: (@escaping @Sendable (ModelLoadProgress) -> Void) async throws -> ModelHold
    ) async throws -> ModelHold {
        let loadID = state.withLock { $0.progress.startLoad(of: ref) }
        let progressHandler: @Sendable (ModelLoadProgress) -> Void = { [weak self] progress in
            self?.deliverProgress { ((), $0.progress.report(progress: progress, of: ref, load: loadID)) }
        }
        do {
            let hold = try await load(progressHandler)
            deliverProgress { ((), $0.progress.endLoad(id: loadID, of: ref, with: .ready)) }
            return hold
        } catch {
            let failure = ModelLoadProgress.failed(error.localizedDescription)
            deliverProgress { ((), $0.progress.endLoad(id: loadID, of: ref, with: failure)) }
            throw error
        }
    }

    /// Makes `container` the resident model of `key`, ends the load that
    /// runs, and gives the first hold.
    ///
    /// - Parameters:
    ///   - key: The model.
    ///   - container: The container that `loader` returned.
    ///   - loader: The loader that evicts the model.
    ///   - bytes: The bytes that the pool counts for the model.
    ///   - sessionBytes: The bytes of the session of the first hold, which
    ///     `bytes` includes.
    /// - Returns: The first hold of the model.
    private func makeResident(
        _ key: ModelPoolKey, container: any Sendable, loader: any PooledModelLoader, bytes: Int64, sessionBytes: Int64
    ) -> ModelHold {
        let entry = Entry(container: container, loader: loader, bytes: bytes)
        publishToEachStream { state in
            state.loadingBytes = 0
            state.entries[key] = entry
        }
        return ModelHold(pool: self, key: key, entry: entry, sessionBytes: sessionBytes)
    }

    /// Sets the bytes of the load that runs now.
    private func setLoadingBytes(_ bytes: Int64) {
        publishToEachStream { $0.loadingBytes = bytes }
    }

    /// Removes one hold. The last hold puts an eviction job in the admission
    /// queue in the same step, so each admission job after it runs after the
    /// eviction job.
    fileprivate func release(_ key: ModelPoolKey, sessionBytes: Int64) {
        // Lock order: the publish lock, the state lock, then the queue lock.
        // No queue code takes a pool lock.
        publishToEachStream { state in
            state.entries[key]?.holds -= 1
            state.entries[key]?.bytes -= sessionBytes
            guard state.entries[key]?.holds == 0 else { return }
            admissions.enqueue { await self.evictIfIdle(key) }
        }
    }

    /// The eviction job: evicts the model of `key` when it still has no hold.
    ///
    /// The model moves from the entries to the evicting models, so it gives
    /// no more holds. The footprint does not change, because the model uses
    /// its memory until the evict call returns. After that call, the pool
    /// removes the model and publishes the new footprint.
    private func evictIfIdle(_ key: ModelPoolKey) async {
        let idle = state.withLock { state -> Entry? in
            guard state.entries[key]?.holds == 0, let idle = state.entries.removeValue(forKey: key) else { return nil }
            state.evicting[key] = idle.bytes
            return idle
        }
        guard let idle else { return }
        await idle.loader.evict(idle.container)
        publishToEachStream { $0.evicting[key] = nil }
    }

    /// Runs `step` under the publish lock and the state lock. Then, under the
    /// publish lock only, yields the new footprint to the streams that `step`
    /// gives.
    ///
    /// - Parameter step: Changes the state. It returns the result for the
    ///   caller, and the streams that must get the new footprint.
    /// - Returns: The result that `step` returns.
    private func publish<Result: Sendable>(
        _ step: (inout State) -> (result: Result, streams: [FootprintContinuation])
    ) -> Result {
        publishing.withLock { _ in
            let (result, streams, footprint) = state.withLock { state in
                let (result, streams) = step(&state)
                return (result, streams, state.footprint)
            }
            for stream in streams {
                stream.yield(footprint)
            }
            return result
        }
    }

    /// Runs `change` under the publish lock and the state lock. Then yields
    /// the new footprint to each live stream. See ``publish(_:)``.
    ///
    /// - Parameter change: Changes the state.
    private func publishToEachStream(_ change: (inout State) -> Void) {
        publish { state in
            change(&state)
            return ((), state.liveStreams)
        }
    }

    /// Runs `step` under the publish lock and the state lock. Then, under the
    /// publish lock only, sends the progress delivery that `step` gives. See
    /// ``publishing``.
    ///
    /// - Parameter step: Changes the state. It returns the result for the
    ///   caller, and the progress values that some streams must get.
    /// - Returns: The result that `step` returns.
    private func deliverProgress<Result: Sendable>(
        _ step: (inout State) -> (result: Result, delivery: ModelLoadProgressDelivery)
    ) -> Result {
        publishing.withLock { _ in
            let (result, delivery) = state.withLock { step(&$0) }
            delivery.send()
            return result
        }
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

    /// Gives a hold of the model of `key`, and loads the model now with the
    /// loader of the pool when it is not resident. See ``ModelPool/acquire(_:)``.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: A hold of the model.
    /// - Throws: The error of the load or of the measure.
    public func acquire(_ key: ModelPoolKey) async throws -> ModelHold {
        if let hold = pool.holdIfResident(key, sessionBytes: ModelPool.measuredSessionBytes) { return hold }
        return try await pool.loadMeasured(key)
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
