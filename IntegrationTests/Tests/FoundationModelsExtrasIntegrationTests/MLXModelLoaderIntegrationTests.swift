import FoundationModelsExtras
import Testing

/// The tokenizer loads that one load of one real model causes.
private let tokenizerLoadsOfOneModelLoad = 1

extension RealModelSuites {
    /// `MLXModelLoader(tokenizerLoader:)` with real models: each load, of an LLM
    /// and of an embedding model, loads the tokenizer with the tokenizer loader
    /// of the init.
    @Suite("MLX model loader with a tokenizer loader", .timeLimit(.minutes(RealModelSuites.testTimeLimitMinutes)))
    struct MLXModelLoaderIntegrationTests {
        @Test(
            "a real load by name through MLXModelLoader(tokenizerLoader:) loads the tokenizer one time with that tokenizer loader",
            arguments: [IntegrationModels.llm, IntegrationModels.embedding])
        func aLoadUsesTheGivenTokenizerLoader(key: ModelPoolKey) async throws {
            try ModelAvailability.requireMetalDevice()
            let tokenizerLoader = RecordingTokenizerLoader()
            let pool = ModelPool(loader: MLXModelLoader(tokenizerLoader: tokenizerLoader))

            // The hold goes at once, thus the eviction job follows the load.
            _ = try await pool.acquire(key)
            try await IntegrationModels.waitForEviction(of: key, in: pool)

            #expect(await tokenizerLoader.directories.events.count == tokenizerLoadsOfOneModelLoad)
        }
    }
}
