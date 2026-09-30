import FoundationModelsExtras
import Testing

/// The most tokens of the generation in the smoke test.
private let smokeResponseTokens = 32

extension RealModelSuites {
    /// Real MLX models through the real `ModelPool`: one load, one call in the
    /// queue of the hold, and an eviction after the last hold goes.
    @Suite("Model pool smoke", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct ModelPoolSmokeTests {
        @Test("the pool loads the real LLM, the queue of the hold runs one generation, and the release evicts the model")
        func generatesThroughThePoolAndEvictsAfterTheRelease() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let answer = try await Self.generate(in: pool, prompt: "What is the capital city of France?")

            #expect(answer.contains("Paris"), "answer: \(answer)")
            try await IntegrationModels.waitForEviction(of: IntegrationModels.llm, in: pool)
            #expect(!pool.isResident(IntegrationModels.llm))
        }

        @Test("the pool loads the real embedding model, and its container embeds through PooledEmbedder")
        func embedsThroughThePoolAndEvictsAfterTheRelease() async throws {
            try ModelAvailability.requireMetalDevice()
            let pool = ModelPool()

            let (vectors, dimension) = try await Self.embed(["a cat", "a dog"], in: pool)

            #expect(dimension > 0)
            #expect(vectors.map(\.count) == [dimension, dimension])
            try await IntegrationModels.waitForEviction(of: IntegrationModels.embedding, in: pool)
            #expect(!pool.isResident(IntegrationModels.embedding))
        }

        /// Acquires the LLM, runs one generation in the queue of the hold, and
        /// releases the hold on return.
        private static func generate(in pool: ModelPool, prompt: String) async throws -> String {
            let hold = try await IntegrationModels.acquire(key: IntegrationModels.llm, in: pool)
            let model = try Generation.languageModel(of: hold)
            return try await hold.queue.submit {
                try await Generation.respond(to: prompt, with: model, maximumResponseTokens: smokeResponseTokens)
            }
        }

        /// Acquires the embedding model, embeds `texts` through a `PooledEmbedder`,
        /// and releases the hold on return.
        private static func embed(_ texts: [String], in pool: ModelPool) async throws -> ([[Float]], Int) {
            let embedder = try PooledEmbedder(hold: try await IntegrationModels.acquire(key: IntegrationModels.embedding, in: pool))
            return (try await embedder.embed(texts: texts), embedder.dimension)
        }
    }
}
