/// One step of the load of a model in a ``ModelPool``.
///
/// ``ModelPool/progress(for:)`` gives these values in order: zero or more
/// ``downloading(fraction:)`` values, then ``loading``, then ``ready`` or
/// ``failed(_:)``. The loader reports the download and the load. The pool
/// reports ``ready`` and ``failed(_:)``, and the stream then ends.
public enum ModelLoadProgress: Sendable, Equatable {
    /// The loader downloads the model. `fraction` is the part of the download
    /// that is done, from 0 to 1.
    case downloading(fraction: Double)
    /// The loader loads the model into memory.
    case loading
    /// The model is resident. This is the last value of a stream.
    case ready
    /// The load failed. The text is the description of the error. This is the
    /// last value of a stream.
    case failed(String)

    /// Whether this value ends the load: ``ready`` or ``failed(_:)``.
    var endsTheLoad: Bool {
        switch self {
        case .ready, .failed: true
        case .downloading, .loading: false
        }
    }

    /// Whether a loader can report this value after `previous`. A download
    /// comes before the load, and the load comes one time. Only the pool ends
    /// a load, thus a loader cannot report ``ready`` or ``failed(_:)``.
    ///
    /// - Parameter previous: The last value of the load, or `nil` before the
    ///   first value.
    /// - Returns: Whether the value keeps the order of the steps.
    func isAllowed(after previous: ModelLoadProgress?) -> Bool {
        switch self {
        case .downloading: previous == nil || previous?.isDownload == true
        case .loading: previous != .loading
        case .ready, .failed: false
        }
    }

    /// Whether this value is a ``downloading(fraction:)`` value.
    private var isDownload: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// The input end of one progress stream of ``ModelPool/progress(for:)``.
typealias ModelLoadProgressObserver = AsyncStream<ModelLoadProgress>.Continuation

/// The values that some progress streams must get. Send them after the state
/// lock of the pool: a finish runs the termination handler of the stream,
/// which takes that lock.
struct ModelLoadProgressDelivery {
    /// A delivery to no stream.
    static let none = ModelLoadProgressDelivery(observers: [], values: [])

    /// The streams that get the values.
    let observers: [ModelLoadProgressObserver]

    /// The values, in order.
    let values: [ModelLoadProgress]

    /// Yields each value to each stream. When the last value ends the load,
    /// finishes each stream.
    func send() {
        let ends = values.last?.endsTheLoad == true
        for observer in observers {
            for value in values {
                observer.yield(value)
            }
            if ends {
                observer.finish()
            }
        }
    }
}

/// The progress streams of each model, and the loads that run now. The pool
/// keeps it in its state, under its state lock.
struct ModelLoadProgressBoard {
    /// A load that runs now.
    private struct RunningLoad {
        /// The id that ``startLoad(of:)`` gave to the load.
        let id: Int
        /// The last value that the streams got, or `nil` before the first.
        var last: ModelLoadProgress?
    }

    /// The live streams of each model, by id.
    private var observers: [ModelRef: [Int: ModelLoadProgressObserver]] = [:]

    /// The load of each model that runs now.
    private var running: [ModelRef: RunningLoad] = [:]

    /// The last id that the board gave to a load or to a stream.
    private var lastID = 0

    /// Starts a load of `ref`.
    ///
    /// - Parameter ref: The model.
    /// - Returns: The id of the load, for ``report(progress:of:load:)`` and
    ///   ``endLoad(id:of:with:)``.
    mutating func startLoad(of ref: ModelRef) -> Int {
        let id = nextID()
        running[ref] = RunningLoad(id: id)
        return id
    }

    /// Adds a stream of `ref`. A stream of a load that runs gets the last
    /// value of the load first. A stream of a model that is ready, with no
    /// load that runs, gets ``ModelLoadProgress/ready`` and ends.
    ///
    /// - Parameters:
    ///   - observer: The input end of the stream.
    ///   - ref: The model.
    ///   - isReady: Whether the model of `ref` is resident and gives holds.
    /// - Returns: The id of the stream for ``removeObserver(id:of:)``, or `nil`
    ///   when the stream ends at once; and the values that the stream gets now.
    mutating func add(
        observer: ModelLoadProgressObserver, of ref: ModelRef, isReady: Bool
    ) -> (id: Int?, delivery: ModelLoadProgressDelivery) {
        if running[ref] == nil, isReady {
            return (nil, ModelLoadProgressDelivery(observers: [observer], values: [.ready]))
        }
        let id = nextID()
        observers[ref, default: [:]][id] = observer
        let replay = running[ref]?.last.map { [$0] } ?? []
        return (id, ModelLoadProgressDelivery(observers: [observer], values: replay))
    }

    /// Removes the stream `id` of `ref`, when it is still live.
    ///
    /// - Parameters:
    ///   - id: The id that ``add(observer:of:isReady:)`` gave.
    ///   - ref: The model.
    mutating func removeObserver(id: Int, of ref: ModelRef) {
        observers[ref]?[id] = nil
        if observers[ref]?.isEmpty == true {
            observers[ref] = nil
        }
    }

    /// A report of the loader of the load `loadID` of `ref`. The board drops a
    /// report of a load that ended, and a report that breaks the order of the
    /// steps. See ``ModelLoadProgress/isAllowed(after:)``.
    ///
    /// - Parameters:
    ///   - progress: The report.
    ///   - ref: The model.
    ///   - loadID: The id that ``startLoad(of:)`` gave to the load.
    /// - Returns: The report for each stream of `ref`, or no delivery.
    mutating func report(
        progress: ModelLoadProgress, of ref: ModelRef, load loadID: Int
    ) -> ModelLoadProgressDelivery {
        guard let load = running[ref], load.id == loadID, progress.isAllowed(after: load.last) else { return .none }
        running[ref]?.last = progress
        return ModelLoadProgressDelivery(observers: liveObservers(of: ref), values: [progress])
    }

    /// Ends the load `loadID` of `ref` with `outcome`, and removes each
    /// stream of `ref`. A load that ends with ``ModelLoadProgress/ready``
    /// gives ``ModelLoadProgress/loading`` first when the loader did not
    /// report it.
    ///
    /// - Parameters:
    ///   - loadID: The id that ``startLoad(of:)`` gave to the load.
    ///   - ref: The model.
    ///   - outcome: ``ModelLoadProgress/ready`` or ``ModelLoadProgress/failed(_:)``.
    /// - Returns: The last values for each stream of `ref`. The delivery
    ///   finishes each stream.
    mutating func endLoad(
        id loadID: Int, of ref: ModelRef, with outcome: ModelLoadProgress
    ) -> ModelLoadProgressDelivery {
        guard let load = running[ref], load.id == loadID else { return .none }
        running[ref] = nil
        let values: [ModelLoadProgress] = outcome == .ready && load.last != .loading ? [.loading, .ready] : [outcome]
        let ended = liveObservers(of: ref)
        observers[ref] = nil
        return ModelLoadProgressDelivery(observers: ended, values: values)
    }

    /// The live streams of `ref`.
    private func liveObservers(of ref: ModelRef) -> [ModelLoadProgressObserver] {
        observers[ref].map { Array($0.values) } ?? []
    }

    /// Gives a new id.
    private mutating func nextID() -> Int {
        lastID += 1
        return lastID
    }
}
