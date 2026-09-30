import FoundationModelsExtras
import MLXFoundationModels
import Testing

/// The divisor that gives the tolerance of a memory check from the bytes of
/// the weights of one model: the tolerance is a tenth of one model, about
/// 70 MB for the 1B LLM.
///
/// A load keeps each tensor of the weight files as one MLX array, thus one load
/// adds about the bytes of the weight files, and the small arrays that the
/// model makes for inference add a little more. On 2026-09-27, on an Apple
/// silicon Mac, the load added 695,312,152 bytes for weight files of
/// 695,283,921 bytes (28 KB more), and less than 7 KB stayed after the
/// eviction. The tolerance thus leaves much space for a different MLX version
/// or a different machine. It is still much smaller than the differences that
/// the checks must see: one model against two models when two holds share a
/// load, one model against no model when the load occurs, and no model against
/// a large part of a model that stays after an eviction.
private let toleranceDivisor = 10

/// The holds that the one-load test acquires at the same time.
private let concurrentHoldCount = 2

extension RealModelSuites {
    /// The real `ModelPool` with real MLX models: one load for each model, the
    /// memory of that load, and the order of the admission queue.
    @Suite("Model pool with real models", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct ModelPoolIntegrationTests {
        @Test("two concurrent acquires of the real LLM load it one time, share one container, and add one model of memory")
        func concurrentAcquiresLoadTheModelOneTime() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let loader = RecordingLoader()
            let weightBytes = try ModelMemory.weightBytes(of: IntegrationModels.llm)

            let holds = try await Self.acquireConcurrently(in: pool, loader: loader)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.llm, in: pool)

            #expect(await loader.loads.events.map(\.key) == [IntegrationModels.llm])
            #expect(holds.shareOneEntry)
            #expect(holds.modelIDs == Array(repeating: IntegrationModels.llm.ref.repo, count: concurrentHoldCount))
            #expect(
                abs(holds.activeGrowth - weightBytes) < weightBytes / toleranceDivisor,
                "MLX active memory grew \(holds.activeGrowth) bytes; one model is \(weightBytes) bytes")
        }

        @Test("after the last release, the eviction job removes the real LLM and MLX frees its memory")
        func evictionFreesTheMemoryOfTheModel() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let weightBytes = try ModelMemory.weightBytes(of: IntegrationModels.llm)
            let tolerance = weightBytes / toleranceDivisor
            let bytesBefore = ModelMemory.activeBytes

            let bytesWhileResident = try await Self.loadAndRelease(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.llm, in: pool)
            let bytesAfter = ModelMemory.activeBytes

            #expect(!pool.isResident(IntegrationModels.llm))
            #expect(
                bytesWhileResident - bytesBefore > weightBytes - tolerance,
                "the load added \(bytesWhileResident - bytesBefore) bytes; one model is \(weightBytes) bytes")
            #expect(
                bytesAfter - bytesBefore < tolerance,
                "after the eviction, \(bytesAfter - bytesBefore) bytes stay of a model of \(weightBytes) bytes")
        }

        @Test("a plain acquire of a second model loads only after the admission job that loads the first model ends")
        func acquireWaitsForTheRunningAdmissionJob() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let loader = RecordingLoader()
            let footprints = pool.footprints

            let timeline = try await Self.admitLLMWhileAcquiringEmbedding(in: pool, loader: loader)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.llm, in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let loads = await loader.loads.events
            let llmLoad = try #require(loads.first)
            let embeddingLoad = try #require(loads.last)
            #expect(timeline.footprintAtJobStart == FootprintStep(resident: [], loadingBytes: 0))
            #expect(loads.map(\.key) == [IntegrationModels.llm, IntegrationModels.embedding])
            #expect(timeline.embeddingRequested < llmLoad.end)
            #expect(llmLoad.end <= timeline.jobEnd)
            #expect(embeddingLoad.start > timeline.jobEnd)
            #expect(await Self.firstSteps(of: footprints) == Self.oneLoadAtATime)
        }

        @Test(
            "two acquires by key through ModelPool() load the real model by name one time, and count the weight files",
            arguments: [IntegrationModels.embedding, IntegrationModels.toolCallingLLM])
        func acquireByKeyLoadsEachModelByName(_ key: ModelPoolKey) async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let holds = try await Self.acquireTwiceByKey(key, in: pool)
            try await IntegrationModels.waitForEviction(of: key, in: pool)

            #expect(holds.shareOneEntry)
            #expect(holds.residentModelCount == 1)
            #expect(holds.footprintBytes > 0)
            #expect(holds.footprintBytes == Int64(try ModelMemory.weightBytes(of: key)))
        }

        @Test("a real load by name through ModelPool() gives its progress in order, and the stream ends with ready")
        func aLoadEndsWithReady() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let key = IntegrationModels.embedding
            let progress = pool.progress(for: key.ref)

            let steps = try await Self.loadAndReadProgress(of: key, in: pool, progress: progress)
            try await IntegrationModels.waitForEviction(of: key, in: pool)

            #expect(Array(steps.drop(while: \.isDownload)) == [.loading, .ready])
        }

        @Test("a load of a repository name that is not valid ends with failed, and gives no other step")
        func aBadRepositoryNameEndsWithFailed() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let key = ModelPoolKey(ref: Self.invalidRepositoryName, role: .embedding)
            let progress = pool.progress(for: key.ref)

            await #expect(throws: (any Error).self) { try await pool.acquire(key) }
            let steps = await progress.reduce(into: []) { $0.append($1) }

            #expect(steps.map(\.isFailure) == [true])
            #expect(!pool.isResident(key))
        }

        /// A repository name that the Hugging Face downloader refuses before
        /// it opens a connection: a repository name has no space.
        private static let invalidRepositoryName: ModelRef = "not a repository"

        /// Acquires `key` by key with the loader of `pool`, releases the hold,
        /// and reads each step of `progress` until the stream ends.
        ///
        /// - Parameters:
        ///   - key: The model to load by name.
        ///   - pool: The pool of the test.
        ///   - progress: A progress stream of `key` that started before the load.
        /// - Returns: The steps of the load, in order.
        /// - Throws: What the load or the measure throws.
        private static func loadAndReadProgress(
            of key: ModelPoolKey, in pool: ModelPool, progress: AsyncStream<ModelLoadProgress>
        ) async throws -> [ModelLoadProgress] {
            let hold = try await pool.acquire(key)
            let steps = await progress.reduce(into: []) { $0.append($1) }
            return withExtendedLifetime(hold) { steps }
        }

        /// Acquires `key` two times by key, with the loader of `pool`, and
        /// releases the holds on return.
        ///
        /// - Parameters:
        ///   - key: The model to load by name.
        ///   - pool: The pool of the test.
        /// - Returns: What the two holds gave.
        /// - Throws: What the load or the measure throws.
        private static func acquireTwiceByKey(_ key: ModelPoolKey, in pool: ModelPool) async throws -> ByKeyHolds {
            let first = try await pool.acquire(key)
            let second = try await pool.acquire(key)
            return ByKeyHolds(
                shareOneEntry: first.queue === second.queue,
                residentModelCount: pool.residentModelCount,
                footprintBytes: pool.footprint.resident[key] ?? 0)
        }

        /// The first footprints of a new pool in which one admission job loads
        /// the LLM and a plain acquire then loads the embedding model.
        private static let oneLoadAtATime = [
            FootprintStep(resident: [], loadingBytes: 0),
            FootprintStep(resident: [], loadingBytes: IntegrationModels.footprintBytes),
            FootprintStep(resident: [IntegrationModels.llm], loadingBytes: 0),
            FootprintStep(resident: [IntegrationModels.llm], loadingBytes: IntegrationModels.footprintBytes),
            FootprintStep(resident: [IntegrationModels.llm, IntegrationModels.embedding], loadingBytes: 0),
        ]

        /// Acquires the LLM with concurrent calls, and releases the holds on
        /// return.
        private static func acquireConcurrently(in pool: ModelPool, loader: RecordingLoader) async throws -> SharedHolds {
            let bytesBefore = ModelMemory.activeBytes
            async let first = IntegrationModels.acquire(key: IntegrationModels.llm, in: pool, loader: loader)
            async let second = IntegrationModels.acquire(key: IntegrationModels.llm, in: pool, loader: loader)
            let holds = try await [first, second]
            return SharedHolds(
                shareOneEntry: holds[0].queue === holds[1].queue,
                modelIDs: try holds.map { try #require($0.container as? MLXLanguageModel).modelID },
                activeGrowth: ModelMemory.activeBytes - bytesBefore)
        }

        /// Loads the LLM, and releases the hold on return.
        ///
        /// - Returns: The MLX active memory while the hold exists.
        private static func loadAndRelease(in pool: ModelPool) async throws -> Int {
            let hold = try await IntegrationModels.acquire(key: IntegrationModels.llm, in: pool)
            return withExtendedLifetime(hold) { ModelMemory.activeBytes }
        }

        /// Runs one admission job that reads the footprint, starts a plain
        /// acquire of the embedding model, and then loads the LLM. Releases the
        /// two holds on return.
        private static func admitLLMWhileAcquiringEmbedding(
            in pool: ModelPool, loader: RecordingLoader
        ) async throws -> AdmissionTimeline {
            let job = try await pool.admit { admission in
                let footprint = FootprintStep(admission.footprint)
                let embedding = Task {
                    let requested = ContinuousClock.now
                    return (requested, try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: loader))
                }
                let hold = try await admission.acquire(
                    IntegrationModels.llm, footprintBytes: IntegrationModels.footprintBytes,
                    sessionBytes: IntegrationModels.sessionBytes, loader: loader)
                return AdmissionJob(footprint: footprint, embedding: embedding, llmHold: hold, end: .now)
            }
            let (requested, embeddingHold) = try await job.embedding.value
            return withExtendedLifetime((job.llmHold, embeddingHold)) {
                AdmissionTimeline(footprintAtJobStart: job.footprint, embeddingRequested: requested, jobEnd: job.end)
            }
        }

        /// Reads the first footprints of a stream that a new pool made.
        private static func firstSteps(of footprints: AsyncStream<ModelPoolFootprint>) async -> [FootprintStep] {
            await footprints.prefix(oneLoadAtATime.count).map(FootprintStep.init).reduce(into: []) { $0.append($1) }
        }
    }
}

/// What the concurrent acquires of one model gave.
private struct SharedHolds {
    /// Whether the holds share one pool entry: the pool gives each hold of an
    /// entry its queue and its container.
    let shareOneEntry: Bool
    /// The model of the container of each hold.
    let modelIDs: [String]
    /// The change of the MLX active memory from before the acquires to after them.
    let activeGrowth: Int
}

/// What two acquires by key of one model gave.
private struct ByKeyHolds {
    /// Whether the holds share one pool entry: the pool gives each hold of an
    /// entry its queue.
    let shareOneEntry: Bool
    /// The number of resident models while the two holds exist.
    let residentModelCount: Int
    /// The bytes that the pool counts for the model while the two holds exist.
    let footprintBytes: Int64
}

/// What the admission job returns.
private struct AdmissionJob: Sendable {
    /// The footprint at the start of the job.
    let footprint: FootprintStep
    /// The plain acquire of the embedding model, which the job started.
    let embedding: Task<(ContinuousClock.Instant, ModelHold), any Error>
    /// The hold of the LLM that the job loaded.
    let llmHold: ModelHold
    /// The time when the job returned.
    let end: ContinuousClock.Instant
}

/// The times of the admission test.
private struct AdmissionTimeline {
    /// The footprint that the admission job read at its start.
    let footprintAtJobStart: FootprintStep
    /// The time when the plain acquire of the embedding model started.
    let embeddingRequested: ContinuousClock.Instant
    /// The time when the admission job returned.
    let jobEnd: ContinuousClock.Instant
}

/// A footprint as the resident models and the bytes of the load that runs.
private struct FootprintStep: Equatable, Sendable {
    /// The resident models.
    let resident: Set<ModelPoolKey>
    /// The bytes of the load that runs, or 0.
    let loadingBytes: Int64
}

extension FootprintStep {
    /// Makes the step of `footprint`.
    init(_ footprint: ModelPoolFootprint) {
        self.init(resident: Set(footprint.resident.keys), loadingBytes: footprint.loadingBytes)
    }
}

extension ModelLoadProgress {
    /// Whether this step is a part of a download.
    fileprivate var isDownload: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// Whether this step is a failure.
    fileprivate var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
