import FoundationModels
import FoundationModelsExtras
import Testing

/// The longest time that one smoke test may take. A first run on a new machine
/// downloads the models.
private let smokeTimeLimitMinutes = 10

/// The most tokens of the generation in the smoke test.
private let smokeResponseTokens = 32

/// Real MLX models through the real `ModelPool`: one load, one call in the
/// queue of the hold, and an eviction after the last hold goes.
@Suite("Model pool smoke", .serialized, .timeLimit(.minutes(smokeTimeLimitMinutes)))
struct ModelPoolSmokeTests {
    @Test("the pool loads the real LLM, the queue of the hold runs one generation, and the release evicts the model")
    func generatesThroughThePoolAndEvictsAfterTheRelease() async throws {
        try ModelAvailability.requireMetalDevice()
        let pool = ModelPool()

        let answer = try await Self.generate(in: pool, prompt: "What is the capital city of France?")

        #expect(answer.contains("Paris"), "answer: \(answer)")
        await Self.waitForEviction(of: IntegrationModels.llm, in: pool)
        #expect(!pool.isResident(IntegrationModels.llm))
    }

    @Test("the pool loads the real embedding model, and its container embeds through PooledEmbedder")
    func embedsThroughThePoolAndEvictsAfterTheRelease() async throws {
        try ModelAvailability.requireMetalDevice()
        let pool = ModelPool()

        let (vectors, dimension) = try await Self.embed(["a cat", "a dog"], in: pool)

        #expect(dimension > 0)
        #expect(vectors.map(\.count) == [dimension, dimension])
        await Self.waitForEviction(of: IntegrationModels.embedding, in: pool)
        #expect(!pool.isResident(IntegrationModels.embedding))
    }

    /// Acquires the LLM, runs one generation in the queue of the hold, and
    /// releases the hold on return.
    private static func generate(in pool: ModelPool, prompt: String) async throws -> String {
        let hold = try await IntegrationModels.acquire(IntegrationModels.llm, in: pool)
        let model = try #require(hold.container as? any LanguageModel)
        return try await hold.queue.submit {
            let session = LanguageModelSession(model: model)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: smokeResponseTokens)
            return try await session.respond(to: prompt, options: options).content
        }
    }

    /// Acquires the embedding model, embeds `texts` through a `PooledEmbedder`,
    /// and releases the hold on return.
    private static func embed(_ texts: [String], in pool: ModelPool) async throws -> ([[Float]], Int) {
        let embedder = try PooledEmbedder(hold: try await IntegrationModels.acquire(IntegrationModels.embedding, in: pool))
        return (try await embedder.embed(texts: texts), embedder.dimension)
    }

    /// Waits until `key` is not resident in `pool`. The release of the last
    /// hold starts the eviction job, which runs after the release returns.
    private static func waitForEviction(of key: ModelPoolKey, in pool: ModelPool) async {
        for await footprint in pool.footprints where footprint.resident[key] == nil {
            return
        }
    }
}
