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

/// Three texts of different token lengths. One batch of them pads the two
/// shorter texts to the length of the longest text.
private enum BatchLengthTexts {
    /// The shortest text.
    static let short = "Open the file."
    /// A text of medium length.
    static let medium = "Find the tool that lists the files of a folder."
    /// The longest text.
    static let long = """
        Summarize the open pull requests of the repository, and give the name of \
        the reviewer of each one, with the date of its last change.
        """
    /// The three texts, in one list.
    static let all = [short, medium, long]
}

/// Many short texts and one long text. In one padded tensor, the long text
/// pads each short text to its length. Divided into sub-batches by token
/// count, the long text goes in a sub-batch by itself.
private enum MixedLengthTexts {
    /// The count of short texts.
    static let shortCount = 15

    /// The count of sentences in the long text: more than 1,000 tokens. One
    /// padded tensor of all the texts is then large enough that the time of
    /// its attention is much more than the fixed time of a model call.
    static let longSentenceCount = 100

    /// The sentence that the long text repeats.
    static let longSentence = "The pool shares one embedding model with each user of the key. "

    /// The long text.
    static let long = String(repeating: longSentence, count: longSentenceCount)

    /// The short texts.
    static let shorts = (1...shortCount).map { "Find the tool number \($0) of the folder." }

    /// The place of the long text in ``all``: in the middle, so that the sort
    /// changes the order of the texts.
    static let longIndex = shortCount / 2

    /// The short texts, with the long text at ``longIndex``.
    static let all = Array(shorts[..<longIndex]) + [long] + Array(shorts[longIndex...])

    /// A list of the length of ``all`` with only copies of the long text.
    /// Its tensor shape is (count) x (longest row), the shape of one padded
    /// call of ``all``, thus its time is the time of one padded call.
    static let paddedEquivalent = Array(repeating: long, count: all.count)
}

/// The smallest ratio of the time of one padded call of ``MixedLengthTexts``
/// to the time of the call of ``MixedLengthTexts/all``. Only one row of the
/// call has the length of the long text, thus the call must be much faster.
private let minimumSpeedupOverPaddedCall = 4.0

/// The lowest cosine between the vector of a text in a batch and the vector of
/// the same text alone. The pad tokens of a batch must not change a vector, thus
/// only the rounding of the float math can make the two vectors differ.
private let batchCosineFloor: Float = 0.999

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
        @Test("a real embed by name gives one vector for each text, and a paraphrase has a higher cosine than an unrelated text")
        func realEmbedByNamePlacesSimilarTextsCloser() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.embedSimilarityTextsByName(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let dimension = try #require(outcome.batch.first).count
            let similar = VectorMath.cosineSimilarity(of: outcome.anchor, to: outcome.paraphrase)
            let unrelated = VectorMath.cosineSimilarity(of: outcome.anchor, to: outcome.unrelated)
            #expect(dimension > 0)
            #expect(outcome.batch.map(\.count) == Array(repeating: dimension, count: SimilarityTexts.all.count))
            #expect([outcome.anchor, outcome.paraphrase, outcome.unrelated].allSatisfy { $0.count == dimension })
            #expect(similar > unrelated, "similar texts: \(similar); unrelated texts: \(unrelated)")
        }

        @Test(
            "each text of a batch of texts of different lengths has the vector of the same text embedded alone",
            arguments: [BatchLengthTexts.all, MixedLengthTexts.all])
        func batchVectorEqualsVectorOfTextAlone(texts: [String]) async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.embedInBatchAndAlone(texts: texts, in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let cosines = zip(outcome.batch, outcome.alone).map { VectorMath.cosineSimilarity(of: $0, to: $1) }
            #expect(outcome.batch.count == texts.count)
            #expect(outcome.alone.count == texts.count)
            #expect(cosines.allSatisfy { $0 >= batchCosineFloor }, "cosines: \(cosines)")
        }

        @Test("a call of short texts and one long text is much faster than one padded call of the same count of texts")
        func mixedLengthCallIsFasterThanOnePaddedCall() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let outcome = try await Self.timeMixedAndPaddedCalls(in: pool)
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)

            let speedup = outcome.paddedDuration / outcome.mixedDuration
            #expect(outcome.mixedVectorCount == MixedLengthTexts.all.count)
            #expect(
                speedup >= minimumSpeedupOverPaddedCall,
                "mixed call: \(outcome.mixedDuration); padded call: \(outcome.paddedDuration)")
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
            let dimension = try #require(outcome.routerVectors.first).count
            #expect(dimension > 0)
            #expect(outcome.registryVectors.map(\.count) == Array(repeating: dimension, count: sharedTexts.count))
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
            let dimension = try #require(outcome.releasedHandleVectors.first).count
            #expect(dimension > 0)
            #expect(outcome.releasedHandleVectors.map(\.count) == [dimension])
            #expect(outcome.remainingHandleVectors.map(\.count) == [dimension])
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
            let dimension = try #require(outcome.vectors.first).count
            #expect(dimension > 0)
            #expect(outcome.vectors.map(\.count) == [dimension])
            #expect(
                outcome.embedEnd < outcome.generationEnd,
                "the embed ended \(outcome.generationEnd - outcome.embedEnd) before the generation")
        }

        /// Makes an embedder that keeps a new hold of the embedding model.
        private static func makeEmbedder(
            in pool: ModelPool, loader: any PooledModelLoader = MLXModelLoader()
        ) async throws -> PooledEmbedder {
            try PooledEmbedder(hold: try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool, loader: loader))
        }

        /// Embeds the similarity texts one at a time and in one batch, through
        /// an embedder made from the name of the embedding model. The first
        /// call loads the model with the loader of `pool`. The embedder goes on
        /// return.
        private static func embedSimilarityTextsByName(in pool: ModelPool) async throws -> SimilarityOutcome {
            let embedder = PooledEmbedder(ref: IntegrationModels.embedding.ref, pool: pool)
            return SimilarityOutcome(
                batch: try await embedder.embed(texts: SimilarityTexts.all),
                anchor: try await vector(of: SimilarityTexts.anchor, with: embedder),
                paraphrase: try await vector(of: SimilarityTexts.paraphrase, with: embedder),
                unrelated: try await vector(of: SimilarityTexts.unrelated, with: embedder))
        }

        /// Embeds `texts` in one batch, and then each text alone, through one
        /// embedder. The embedder goes on return.
        private static func embedInBatchAndAlone(texts: [String], in pool: ModelPool) async throws -> BatchOutcome {
            let embedder = try await makeEmbedder(in: pool)
            return BatchOutcome(
                batch: try await embedder.embed(texts: texts),
                alone: try await embedSerially(texts, with: embedder))
        }

        /// Embeds a probe text to warm up the model, then measures one call of
        /// ``MixedLengthTexts/paddedEquivalent`` and one call of
        /// ``MixedLengthTexts/all``, through one embedder. The embedder goes on
        /// return.
        private static func timeMixedAndPaddedCalls(in pool: ModelPool) async throws -> MixedTimingOutcome {
            let embedder = try await makeEmbedder(in: pool)
            _ = try await embedder.embed(texts: [probeText])
            let padded = try await timedEmbed(of: MixedLengthTexts.paddedEquivalent, with: embedder)
            let mixed = try await timedEmbed(of: MixedLengthTexts.all, with: embedder)
            return MixedTimingOutcome(
                mixedVectorCount: mixed.vectors.count, mixedDuration: mixed.duration, paddedDuration: padded.duration)
        }

        /// Embeds `texts` in one call, and measures the time of the call.
        private static func timedEmbed(
            of texts: [String], with embedder: PooledEmbedder
        ) async throws -> (vectors: [[Float]], duration: Duration) {
            let start = ContinuousClock.now
            let vectors = try await embedder.embed(texts: texts)
            return (vectors, start.duration(to: .now))
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
            let remainingHold = try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool)
            let remaining = try PooledEmbedder(hold: remainingHold)
            let releasedHandleVectors = try await embedWithShortLivedHandle(in: pool)
            // An eviction job runs in the admission queue. This empty job ends
            // after each eviction job that is in the admission queue now.
            try await pool.admit { _ in }
            return ResidencyOutcome(
                isResidentAfterFirstRelease: pool.isResident(IntegrationModels.embedding),
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
                shareOneQueue: llmHold.queue === embeddingHold.queue,
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
    /// The vectors of one call with all the similarity texts.
    let batch: [[Float]]
    /// The vector of ``SimilarityTexts/anchor``, embedded alone.
    let anchor: [Float]
    /// The vector of ``SimilarityTexts/paraphrase``, embedded alone.
    let paraphrase: [Float]
    /// The vector of ``SimilarityTexts/unrelated``, embedded alone.
    let unrelated: [Float]
}

/// The vectors of the batch test.
private struct BatchOutcome {
    /// The vector of each text, from one call with all the texts.
    let batch: [[Float]]
    /// The vector of each text, from one call for each text.
    let alone: [[Float]]
}

/// The times of the mixed-length test.
private struct MixedTimingOutcome {
    /// The count of vectors of the call of ``MixedLengthTexts/all``.
    let mixedVectorCount: Int
    /// The time of the call of ``MixedLengthTexts/all``.
    let mixedDuration: Duration
    /// The time of the call of ``MixedLengthTexts/paddedEquivalent``.
    let paddedDuration: Duration
}

/// What the two users of one embedding model observed.
private struct SharedModelOutcome {
    /// Whether the holds of the two users share one queue, thus one pool entry.
    let shareOneQueue: Bool
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
    /// The vectors of the handle that the test released first.
    let releasedHandleVectors: [[Float]]
    /// The vectors of the remaining handle, after the release of the first handle.
    let remainingHandleVectors: [[Float]]
}

/// What the test of an embed call during a generation observed.
private struct GenerationOverlapOutcome {
    /// Whether the LLM and the embedding model share one queue.
    let shareOneQueue: Bool
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

    /// Embeds `texts` with the wrapped embedding, and records the call.
    func embed(texts: [String]) async throws -> [[Float]] {
        let start = ContinuousClock.now
        let vectors = try await embedding.embed(texts: texts)
        await records.append(EmbedRecord(texts: texts, start: start, end: .now))
        return vectors
    }
}

/// A loader that loads the MLX embedding model with `MLXModelLoader`, and
/// gives it wrapped in a ``RecordingEmbedding``. The first loader of a key gives
/// the container of all holds, thus each user of the key records its calls here.
private struct RecordingEmbeddingLoader: PooledModelLoader {
    /// The embed calls of each user of the loaded model.
    let records = EventLog<EmbedRecord>()

    /// The loader that does the real work.
    private let loader = MLXModelLoader()

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

    /// Evicts the container with `MLXModelLoader`.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await loader.evict(container)
    }
}
