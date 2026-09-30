import FoundationModels
import FoundationModelsExtras
import Testing

/// The most tokens of the long generation that runs while an embed call runs.
/// The model cannot finish the prompt early, thus the generation runs for some
/// seconds, and one embed call takes much less time.
private let longGenerationTokens = 1024

/// A question that the model answers until its token limit.
private let endlessPrompt = "Count upward from 1, one number per line, without stopping."

/// A text that a test embeds when only the shape of the result is important.
private let probeText = "The pool shares one embedding model."

/// Three texts: two that have the same meaning, and one that has an unrelated
/// meaning.
private enum SimilarityTexts {
    /// The text that the other two are compared with.
    static let anchor = "A cat sleeps on the warm windowsill."
    /// A different text with the meaning of ``anchor``.
    static let paraphrase = "A kitten naps in the sun by the window."
    /// A text with a meaning that is not related to ``anchor``.
    static let unrelated = "The central bank raised the interest rate by half a percent."
    /// The three texts, in one list.
    static let all = [anchor, paraphrase, unrelated]
}

/// The texts that the two users of one embedding model embed.
private let sharedTexts = ["Route this question to the best model.", "Find the tool that reads a file."]

/// A user of the shared embedding model.
private enum EmbedderUser {
    /// The router, which embeds the prompts.
    case router
    /// The metadata registry, which embeds the descriptions of the tools.
    case registry
}

/// One embed call of the FIFO test: the user that makes it and its one text.
private struct EmbedCall {
    /// The user that calls `embed(texts:)`.
    let user: EmbedderUser
    /// The text of the call.
    let text: String
}

/// The concurrent embed calls of the FIFO test, in the order in which they go
/// into the queue. The two users take turns.
private let concurrentCalls = [
    EmbedCall(user: .router, text: "Summarize the open pull requests."),
    EmbedCall(user: .registry, text: "A tool that lists the files of a folder."),
    EmbedCall(user: .router, text: "Write a unit test for the parser."),
    EmbedCall(user: .registry, text: "A tool that runs a shell command."),
    EmbedCall(user: .router, text: "Explain the last build failure."),
    EmbedCall(user: .registry, text: "A tool that searches the code for a symbol."),
]

extension RealModelSuites {
    /// `PooledEmbedder` with the real MLX embedding model: real vectors, one
    /// model that two users share, one embed call at a time on the queue of the
    /// model, and the residency that the embedder handles keep.
    @Suite("Pooled embedder with a real model", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct PooledEmbedderIntegrationTests {
        @Test("a real embed gives vectors of the model dimension, and two similar texts are closer than two unrelated texts")
        func realEmbedPlacesSimilarTextsCloser() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.embedSimilarityTexts(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let similar = VectorMath.cosineSimilarity(of: outcome.anchor, to: outcome.paraphrase)
            let unrelated = VectorMath.cosineSimilarity(of: outcome.anchor, to: outcome.unrelated)
            #expect(outcome.dimension > 0)
            #expect(outcome.batch.map(\.count) == Array(repeating: outcome.dimension, count: SimilarityTexts.all.count))
            #expect(
                [outcome.anchor, outcome.paraphrase, outcome.unrelated].allSatisfy { $0.count == outcome.dimension })
            #expect(similar > unrelated, "similar texts: \(similar); unrelated texts: \(unrelated)")
        }

        @Test("a router and a registry acquire one embedding key, the model loads one time, and the registry embeds with the router container")
        func twoUsersShareOneLoadOfTheModel() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let routerLoader = RecordingLoader()
            let registryLoader = RecordingLoader()

            let outcome = try await Self.shareOneModel(in: pool, routerLoader: routerLoader, registryLoader: registryLoader)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            #expect(await routerLoader.loads.events.map(\.key) == [IntegrationModels.embedding])
            #expect(await registryLoader.loads.events.isEmpty)
            #expect(outcome.shareOneQueue)
            #expect(outcome.registryVectors.map(\.count) == Array(repeating: outcome.dimension, count: sharedTexts.count))
            #expect(outcome.registryVectors == outcome.routerVectors)
        }

        @Test("concurrent embed calls of two users run one at a time, first in first out, and each gives the vectors of a serial run")
        func concurrentEmbedsRunOneAtATimeInOrder() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()
            let loader = RecordingEmbeddingLoader()

            let outcome = try await Self.embedConcurrently(in: pool, loader: loader)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            // The serial run made the first records, and the concurrent calls made the rest.
            let records = await Array(loader.records.events.dropFirst(concurrentCalls.count))
            #expect(records.map(\.texts) == concurrentCalls.map { [$0.text] })
            #expect(zip(records, records.dropFirst()).allSatisfy { $1.start >= $0.end }, "calls: \(records)")
            #expect(outcome.concurrentVectors == outcome.serialVectors)
        }

        @Test("an embedder handle keeps the real model resident, and the release of the last handle evicts it")
        func embedderHandleKeepsTheModelResident() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.releaseOneOfTwoHandles(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            #expect(outcome.isResidentAfterFirstRelease)
            #expect(outcome.releasedHandleVectors.map(\.count) == [outcome.dimension])
            #expect(outcome.remainingHandleVectors.map(\.count) == [outcome.dimension])
            #expect(!pool.isResident(IntegrationModels.embedding))
        }

        @Test("with the real LLM and the real embedding model resident, an embed call does not wait behind a long generation")
        func embedDoesNotWaitBehindAGeneration() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.embedDuringGeneration(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.llm, in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            #expect(!outcome.shareOneQueue)
            #expect(outcome.vectors.map(\.count) == [outcome.dimension])
            #expect(
                outcome.embedEnd < outcome.generationEnd,
                "the embed ended \(outcome.generationEnd - outcome.embedEnd) before the generation")
        }

        /// Makes an embedder that keeps a new hold of the embedding model.
        private static func makeEmbedder(
            in pool: ModelPool, loader: any PooledModelLoader = MLXPooledLoader()
        ) async throws -> PooledEmbedder {
            try PooledEmbedder(hold: try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: loader))
        }

        /// Embeds the similarity texts one at a time and in one batch. The
        /// embedder goes on return.
        private static func embedSimilarityTexts(in pool: ModelPool) async throws -> SimilarityOutcome {
            let embedder = try await makeEmbedder(in: pool)
            return SimilarityOutcome(
                dimension: embedder.dimension,
                batch: try await embedder.embed(texts: SimilarityTexts.all),
                anchor: try await vector(of: SimilarityTexts.anchor, with: embedder),
                paraphrase: try await vector(of: SimilarityTexts.paraphrase, with: embedder),
                unrelated: try await vector(of: SimilarityTexts.unrelated, with: embedder))
        }

        /// Embeds `text` alone, and gives its one vector.
        private static func vector(of text: String, with embedder: PooledEmbedder) async throws -> [Float] {
            try #require(try await embedder.embed(texts: [text]).first)
        }

        /// Acquires the embedding model first for the router and then for the
        /// registry, each with its own loader, and embeds the shared texts
        /// through the embedder of each. The holds go on return.
        private static func shareOneModel(
            in pool: ModelPool, routerLoader: RecordingLoader, registryLoader: RecordingLoader
        ) async throws -> SharedModelOutcome {
            let routerHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: routerLoader)
            let registryHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: registryLoader)
            let router = try PooledEmbedder(hold: routerHold)
            let registry = try PooledEmbedder(hold: registryHold)
            return SharedModelOutcome(
                shareOneQueue: routerHold.queue === registryHold.queue,
                dimension: registry.dimension,
                routerVectors: try await router.embed(texts: sharedTexts),
                registryVectors: try await registry.embed(texts: sharedTexts))
        }

        /// Embeds the text of each concurrent call first in a serial run, and
        /// then in concurrent calls of the two users. A first job holds the
        /// queue until all the concurrent calls wait in it. The holds go on
        /// return.
        private static func embedConcurrently(in pool: ModelPool, loader: RecordingEmbeddingLoader) async throws -> ConcurrentOutcome {
            let routerHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: loader)
            let queue = routerHold.queue
            let users = EmbedderUsers(
                router: try PooledEmbedder(hold: routerHold), registry: try await makeEmbedder(in: pool, loader: loader))
            let serialVectors = try await embedSerially(concurrentCalls.map(\.text), with: users.router)
            async let firstJob: Void = queue.submit {
                try await Waiting.until { await queue.waitingCount == concurrentCalls.count }
            }
            let concurrentVectors = try await embedInTurns(concurrentCalls, with: users, on: queue)
            try await firstJob
            return ConcurrentOutcome(serialVectors: serialVectors, concurrentVectors: concurrentVectors)
        }

        /// Embeds each text in its own call, one call after the other.
        private static func embedSerially(_ texts: [String], with embedder: PooledEmbedder) async throws -> [[Float]] {
            let (stream, continuation) = AsyncStream.makeStream(of: String.self)
            for text in texts {
                continuation.yield(text)
            }
            continuation.finish()
            return try await stream.reduce(into: []) { vectors, text in
                vectors.append(try await vector(of: text, with: embedder))
            }
        }

        /// Makes `calls` concurrently, while a first job runs in `queue`. The
        /// call at place `index` goes into `queue` when `index` calls wait
        /// there, thus the calls go into the queue in the order of `calls`.
        ///
        /// - Returns: The one vector of each call, in the order of `calls`.
        private static func embedInTurns(
            _ calls: [EmbedCall], with users: EmbedderUsers, on queue: GenerationQueue
        ) async throws -> [[Float]] {
            let vectorsByIndex: [Int: [Float]] = try await withThrowingTaskGroup(of: (index: Int, vector: [Float]).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask {
                        try await Waiting.until { await isTurn(index: index, of: queue) }
                        return (index, try await vector(of: call.text, with: users.embedder(for: call.user)))
                    }
                }
                return try await group.reduce(into: [:]) { $0[$1.index] = $1.vector }
            }
            return try calls.indices.map { try #require(vectorsByIndex[$0]) }
        }

        /// Whether the call at place `index` may go into `queue` now: a job
        /// runs, and `index` calls wait behind it.
        private static func isTurn(index: Int, of queue: GenerationQueue) async -> Bool {
            let isRunning = await queue.isRunning
            let waitingCount = await queue.waitingCount
            return isRunning && waitingCount == index
        }

        /// Makes two embedder handles, embeds with each, and releases one of
        /// them. The other handle goes on return.
        private static func releaseOneOfTwoHandles(in pool: ModelPool) async throws -> ResidencyOutcome {
            let remaining = try await makeEmbedder(in: pool)
            let releasedHandleVectors = try await embedWithShortLivedHandle(in: pool)
            // An eviction job runs in the admission queue. This empty job ends
            // after each eviction job that is in the admission queue now.
            try await pool.admit { _ in }
            return ResidencyOutcome(
                isResidentAfterFirstRelease: pool.isResident(IntegrationModels.embedding),
                dimension: remaining.dimension,
                releasedHandleVectors: releasedHandleVectors,
                remainingHandleVectors: try await remaining.embed(texts: [probeText]))
        }

        /// Embeds with a new embedder handle. The handle goes on return.
        private static func embedWithShortLivedHandle(in pool: ModelPool) async throws -> [[Float]] {
            try await makeEmbedder(in: pool).embed(texts: [probeText])
        }

        /// Starts a long generation on the queue of the LLM, and embeds while
        /// it runs. The holds go on return.
        private static func embedDuringGeneration(in pool: ModelPool) async throws -> GenerationOverlapOutcome {
            let llmHold = try await IntegrationModels.acquire(key: IntegrationModels.llm, in: pool)
            let model = try Generation.languageModel(of: llmHold)
            let embeddingHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool)
            let embedder = try PooledEmbedder(hold: embeddingHold)
            let generationStarts = EventLog<ContinuousClock.Instant>()
            async let generationEnd = llmHold.queue.submit {
                await generationStarts.append(.now)
                _ = try await Generation.respond(to: endlessPrompt, with: model, maximumResponseTokens: longGenerationTokens)
                return ContinuousClock.now
            }
            try await Waiting.until { await !generationStarts.events.isEmpty }
            let vectors = try await embedder.embed(texts: [probeText])
            let embedEnd = ContinuousClock.now
            return GenerationOverlapOutcome(
                shareOneQueue: llmHold.queue === embeddingHold.queue, dimension: embedder.dimension,
                vectors: vectors, embedEnd: embedEnd, generationEnd: try await generationEnd)
        }
    }
}

/// The math of the similarity check.
private enum VectorMath {
    /// The cosine of the angle between two vectors of one length.
    static func cosineSimilarity(of first: [Float], to second: [Float]) -> Float {
        zip(first, second).lazy.map(*).reduce(0, +) / (length(of: first) * length(of: second))
    }

    /// The Euclidean length of `vector`.
    private static func length(of vector: [Float]) -> Float {
        vector.lazy.map { $0 * $0 }.reduce(0, +).squareRoot()
    }
}

/// The embedder of each user in the FIFO test.
private struct EmbedderUsers: Sendable {
    /// The embedder of the router.
    let router: PooledEmbedder
    /// The embedder of the registry.
    let registry: PooledEmbedder

    /// The embedder of `user`.
    func embedder(for user: EmbedderUser) -> PooledEmbedder {
        switch user {
        case .router: router
        case .registry: registry
        }
    }
}

/// The vectors of the similarity test.
private struct SimilarityOutcome {
    /// The dimension that the embedder reports.
    let dimension: Int
    /// The vectors of one call with all the similarity texts.
    let batch: [[Float]]
    /// The vector of ``SimilarityTexts/anchor``, embedded alone.
    let anchor: [Float]
    /// The vector of ``SimilarityTexts/paraphrase``, embedded alone.
    let paraphrase: [Float]
    /// The vector of ``SimilarityTexts/unrelated``, embedded alone.
    let unrelated: [Float]
}

/// What the two users of one embedding model observed.
private struct SharedModelOutcome {
    /// Whether the holds of the two users share one queue, thus one pool entry.
    let shareOneQueue: Bool
    /// The dimension that the embedder of the registry reports.
    let dimension: Int
    /// The vectors of the shared texts through the embedder of the router.
    let routerVectors: [[Float]]
    /// The vectors of the shared texts through the embedder of the registry.
    let registryVectors: [[Float]]
}

/// The vectors of the FIFO test.
private struct ConcurrentOutcome {
    /// The vector of each call text, from one call after the other.
    let serialVectors: [[Float]]
    /// The vector of each concurrent call, in the order of the calls.
    let concurrentVectors: [[Float]]
}

/// What the residency test observed.
private struct ResidencyOutcome {
    /// Whether the model was resident after the release of the first handle.
    let isResidentAfterFirstRelease: Bool
    /// The dimension that the remaining embedder reports.
    let dimension: Int
    /// The vectors of the handle that the test released first.
    let releasedHandleVectors: [[Float]]
    /// The vectors of the remaining handle, after the release of the first handle.
    let remainingHandleVectors: [[Float]]
}

/// What the test of an embed call during a generation observed.
private struct GenerationOverlapOutcome {
    /// Whether the LLM and the embedding model share one queue.
    let shareOneQueue: Bool
    /// The dimension that the embedder reports.
    let dimension: Int
    /// The vectors of the embed call.
    let vectors: [[Float]]
    /// The time when the embed call returned.
    let embedEnd: ContinuousClock.Instant
    /// The time when the generation ended.
    let generationEnd: ContinuousClock.Instant
}

/// One embed call that a ``RecordingEmbedding`` ran.
private struct EmbedRecord: Sendable {
    /// The texts of the call.
    let texts: [String]
    /// The time when the call started.
    let start: ContinuousClock.Instant
    /// The time when the call ended.
    let end: ContinuousClock.Instant
}

/// A ``PooledEmbedding`` that records each call of the embedding it wraps.
private struct RecordingEmbedding: PooledEmbedding {
    /// The embedding that does the real work.
    let embedding: any PooledEmbedding
    /// The completed calls, in the order in which they ended.
    let records: EventLog<EmbedRecord>

    /// The length of each vector of the wrapped embedding.
    var dimension: Int { embedding.dimension }

    /// Embeds `texts` with the wrapped embedding, and records the call.
    func embed(texts: [String]) async throws -> [[Float]] {
        let start = ContinuousClock.now
        let vectors = try await embedding.embed(texts: texts)
        await records.append(EmbedRecord(texts: texts, start: start, end: .now))
        return vectors
    }
}

/// A loader that loads the MLX embedding model with ``MLXPooledLoader``, and
/// gives it wrapped in a ``RecordingEmbedding``. The first loader of a key gives
/// the container of all holds, thus each user of the key records its calls here.
private struct RecordingEmbeddingLoader: PooledModelLoader {
    /// The embed calls of each user of the loaded model.
    let records = EventLog<EmbedRecord>()

    /// The loader that does the real work.
    private let loader = MLXPooledLoader()

    /// Loads the model of `key`, and wraps it.
    ///
    /// - Parameter key: An embedding model.
    /// - Returns: A ``RecordingEmbedding``.
    /// - Throws: The error of the load, or a failed expectation when the
    ///   container is not a ``PooledEmbedding``.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        let embedding = try #require(try await loader.load(key) as? any PooledEmbedding)
        return RecordingEmbedding(embedding: embedding, records: records)
    }

    /// Evicts the container with ``MLXPooledLoader``.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await loader.evict(container)
    }
}
