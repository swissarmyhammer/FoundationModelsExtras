@testable import FoundationModelsExtras
import Testing

/// The pool gives the progress of each load of a model as a stream: the
/// download and the load that the loader reports, and then `ready` or
/// `failed` from the pool. The stream then ends.
///
/// The suite has a time limit, because a stream that does not end makes its
/// test wait forever.
@Suite("Model pool: the load progress stream", .timeLimit(.minutes(1)))
struct ModelLoadProgressTests {
    /// The key that each test acquires.
    private static let key = ModelPoolKey(ref: "org/a", role: .llm)

    /// The bytes that an acquire with its own loader counts.
    private static let footprintBytes: Int64 = 10

    /// The bytes of the session of an acquire with its own loader.
    private static let sessionBytes: Int64 = 2

    /// The download fraction of a report that the pool must drop.
    private static let droppedDownloadFraction = 0.5

    /// The progress of a load of a ``ReportingLoader``, then `ready`.
    private static let readySequence = ReportingLoader.reports + [.ready]

    /// The progress of a load of a loader that reports nothing, then `ready`.
    private static let silentReadySequence: [ModelLoadProgress] = [.loading, .ready]

    @Test("a load gives the download, then loading, then ready, in that order, and the stream then ends")
    func aLoadGivesItsProgressInOrder() async throws {
        let pool = ModelPool(loader: ReportingLoader())
        let progress = pool.progress(for: Self.key.ref)

        let hold = try await pool.acquire(Self.key)

        #expect(await Self.values(of: progress) == Self.readySequence)
        #expect(hold.key == Self.key)
    }

    @Test("two observers of one load see the same sequence")
    func twoObserversSeeTheSameSequence() async throws {
        let pool = ModelPool(loader: ReportingLoader())
        let first = pool.progress(for: Self.key.ref)
        let second = pool.progress(for: Self.key.ref)

        let hold = try await pool.acquire(Self.key)

        #expect(await Self.values(of: first) == Self.readySequence)
        #expect(await Self.values(of: second) == Self.readySequence)
        #expect(hold.key == Self.key)
    }

    @Test("a stream that starts after ready gives ready at once, and then ends")
    func aLateObserverGivesReadyAtOnce() async throws {
        let pool = ModelPool(loader: ReportingLoader())
        let hold = try await pool.acquire(Self.key)

        let progress = pool.progress(for: Self.key.ref)

        #expect(await Self.values(of: progress) == [.ready])
        #expect(hold.key == Self.key)
    }

    @Test("a stream that starts during the load gives the last progress first, then the rest")
    func anObserverDuringTheLoadGivesTheLastProgressFirst() async throws {
        let (loadMayEnd, endLoad) = AsyncStream.makeStream(of: Void.self)
        let loader = ReportingLoader(loadMayEnd: loadMayEnd)
        let pool = ModelPool(loader: loader)
        let acquire = Task { try await pool.acquire(Self.key) }
        try #require(await BoundedWait.conditionReached("the loader reports") { loader.hasReported })

        let progress = pool.progress(for: Self.key.ref)
        endLoad.finish()
        let hold = try await acquire.value

        #expect(await Self.values(of: progress) == Self.silentReadySequence)
        #expect(hold.key == Self.key)
    }

    @Test("a failed load gives the reports of the loader, then failed with the description of the error")
    func aFailedLoadGivesFailed() async throws {
        let pool = ModelPool(loader: ReportingLoader(fails: true))
        let progress = pool.progress(for: Self.key.ref)

        await #expect(throws: FakeLoadError.self) { try await pool.acquire(Self.key) }

        let failed = ModelLoadProgress.failed(FakeLoadError().localizedDescription)
        #expect(await Self.values(of: progress) == ReportingLoader.reports + [failed])
    }

    @Test("a loader that reports nothing still gives loading, then ready")
    func aSilentLoaderGivesLoadingThenReady() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>()))
        let progress = pool.progress(for: Self.key.ref)

        let hold = try await pool.acquire(Self.key)

        #expect(await Self.values(of: progress) == Self.silentReadySequence)
        #expect(hold.key == Self.key)
    }

    @Test("a loader that reports nothing still gives loading, then failed")
    func aSilentLoaderGivesLoadingThenFailed() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>(), failingLoads: 1))
        let progress = pool.progress(for: Self.key.ref)

        await #expect(throws: FakeLoadError.self) { try await pool.acquire(Self.key) }

        #expect(await Self.values(of: progress) == [.loading, .failed(FakeLoadError().localizedDescription)])
    }

    @Test("a failed footprint measure gives failed, and not ready")
    func aFailedMeasureGivesFailed() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>(), failingMeasures: 1))
        let progress = pool.progress(for: Self.key.ref)

        await #expect(throws: FakeMeasureError.self) { try await pool.acquire(Self.key) }

        #expect(await Self.values(of: progress) == [.loading, .failed(FakeMeasureError().localizedDescription)])
    }

    @Test("an acquire with its own loader gives the progress of that loader")
    func anAcquireWithItsOwnLoaderGivesItsProgress() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>()))
        let progress = pool.progress(for: Self.key.ref)

        let hold = try await pool.acquire(
            Self.key, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes, loader: ReportingLoader())

        #expect(await Self.values(of: progress) == Self.readySequence)
        #expect(hold.key == Self.key)
    }

    @Test("the pool drops a download after loading, and a ready or a failed that the loader reports")
    func thePoolKeepsTheOrderOfTheStages() async throws {
        let outOfOrder: [ModelLoadProgress] = [
            .loading, .downloading(fraction: Self.droppedDownloadFraction), .ready, .failed("loader"),
        ]
        let pool = ModelPool(loader: ReportingLoader(reports: outOfOrder))
        let progress = pool.progress(for: Self.key.ref)

        let hold = try await pool.acquire(Self.key)

        #expect(await Self.values(of: progress) == Self.silentReadySequence)
        #expect(hold.key == Self.key)
    }

    @Test("a report of an earlier load has no effect on the load that runs now")
    func aReportOfAnEarlierLoadHasNoEffect() async throws {
        let earlierLoader = ReportingLoader()
        let pool = ModelPool(loader: earlierLoader)
        try await Self.loadAndEvict(in: pool)
        let (loadMayEnd, endLoad) = AsyncStream.makeStream(of: Void.self)
        let log = Recorder<String>()
        let laterLoader = RecordingLoader(name: "B", log: log, loadsMayEnd: loadMayEnd)
        let progress = pool.progress(for: Self.key.ref)
        let acquire = Task {
            try await pool.acquire(
                Self.key, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes, loader: laterLoader)
        }
        try #require(await BoundedWait.conditionReached("the later load starts") { !log.values.isEmpty })

        earlierLoader.reportAgain(progress: .downloading(fraction: Self.droppedDownloadFraction))
        endLoad.finish()
        let hold = try await acquire.value

        #expect(await Self.values(of: progress) == Self.silentReadySequence)
        #expect(hold.key == Self.key)
    }

    @Test("the README example: observe the progress of a load")
    func readmeProgressExample() async throws {
        let pool = ModelPool(loader: ReportingLoader())
        let chat = Self.key
        let seen = Recorder<ModelLoadProgress>()
        let show: @Sendable (ModelLoadProgress) -> Void = { seen.append($0) }

        // README example: begin
        let progress = pool.progress(for: chat.ref)
        async let hold = pool.acquire(chat)
        for await step in progress {
            show(step)   // downloading(fraction:)..., loading, then ready or failed
        }
        // README example: end

        #expect(try await hold.key == chat)
        #expect(seen.values == Self.readySequence)
    }

    /// Acquires ``key`` with the loader of `pool`, releases the hold, and
    /// waits until the eviction job ended.
    ///
    /// - Parameter pool: The pool of the test.
    /// - Throws: What the load throws.
    private static func loadAndEvict(in pool: ModelPool) async throws {
        _ = try await pool.acquire(key)
        try #require(await BoundedWait.conditionReached("the eviction ends") { !pool.isResident(key) })
        try await pool.admit { _ in }
    }

    /// Reads each value of `progress` until the stream ends.
    ///
    /// - Parameter progress: A stream of ``ModelPool/progress(for:)``.
    /// - Returns: The values, in order.
    private static func values(of progress: AsyncStream<ModelLoadProgress>) async -> [ModelLoadProgress] {
        await progress.reduce(into: []) { $0.append($1) }
    }
}

/// A loader that reports progress: each value of `reports`, and then it waits
/// until `loadMayEnd` finishes. It then gives a ``FakeModel``, or throws
/// ``FakeLoadError``. Its eviction does nothing.
///
/// The loader keeps the progress handler of each load, so that a test can
/// report to a load again after it ended.
private struct ReportingLoader: PooledModelLoader {
    /// The fraction of the download in the first default report.
    private static let firstDownloadFraction = 0.25

    /// The fraction of the download in the second default report.
    private static let secondDownloadFraction = 0.75

    /// The default reports: two parts of a download, then the load.
    static let reports: [ModelLoadProgress] = [
        .downloading(fraction: firstDownloadFraction), .downloading(fraction: secondDownloadFraction), .loading,
    ]

    /// The reports of each load, in order.
    private let reports: [ModelLoadProgress]

    /// A load ends only after this stream finishes.
    private let loadMayEnd: AsyncStream<Void>

    /// Whether each load throws ``FakeLoadError``.
    private let fails: Bool

    /// The progress handler of each load, in order.
    private let handlers = Recorder<@Sendable (ModelLoadProgress) -> Void>()

    /// Makes a loader.
    ///
    /// - Parameters:
    ///   - reports: The reports of each load. The default is ``reports``.
    ///   - loadMayEnd: A load ends only after this stream finishes. The
    ///     default stream is finished, so a load ends at once.
    ///   - fails: Whether each load throws ``FakeLoadError``.
    init(
        reports: [ModelLoadProgress] = Self.reports,
        loadMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        fails: Bool = false
    ) {
        self.reports = reports
        self.loadMayEnd = loadMayEnd
        self.fails = fails
    }

    /// Whether a load reported its progress.
    var hasReported: Bool { !handlers.values.isEmpty }

    /// Reports each value of ``reports``, keeps the handler, and waits until
    /// ``loadMayEnd`` finishes.
    ///
    /// - Parameters:
    ///   - key: The key to load.
    ///   - progressHandler: Gets each report.
    /// - Returns: A new ``FakeModel``.
    /// - Throws: ``FakeLoadError`` when ``fails`` is true.
    func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        for report in reports {
            progressHandler(report)
        }
        handlers.append(progressHandler)
        for await _ in loadMayEnd {}
        if fails {
            throw FakeLoadError()
        }
        return FakeModel(loaderName: key.ref.stringValue)
    }

    /// Loads with a handler that drops each report.
    ///
    /// - Parameter key: The key to load.
    /// - Returns: A new ``FakeModel``.
    /// - Throws: ``FakeLoadError`` when ``fails`` is true.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try await load(key: key) { _ in }
    }

    /// Does nothing.
    ///
    /// - Parameter container: The container to evict.
    func evict(_ container: any Sendable) async {}

    /// Reports `progress` to the handler of the last load.
    ///
    /// - Parameter progress: The report.
    func reportAgain(progress: ModelLoadProgress) {
        handlers.values.last?(progress)
    }
}
