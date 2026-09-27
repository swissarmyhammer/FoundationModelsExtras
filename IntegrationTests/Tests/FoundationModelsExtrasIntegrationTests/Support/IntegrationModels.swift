import FoundationModelsExtras

/// The real models of this suite, in one place.
///
/// These are small models that the FoundationModelsRouter integration suite
/// also loads, thus the model cache of the CI runner holds them already.
enum IntegrationModels {
    /// A small instruct LLM, about 0.7 GB of weights.
    static let llm = ModelPoolKey(ref: "mlx-community/Llama-3.2-1B-Instruct-4bit", role: .llm)

    /// A small embedding model, about 0.3 GB of weights.
    static let embedding = ModelPoolKey(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", role: .embedding)

    /// The bytes that the pool counts for the weights and one session of each
    /// model. This is a rough upper limit for both models.
    static let footprintBytes: Int64 = 1 << 30

    /// The bytes that the pool counts for the session of each hold.
    static let sessionBytes: Int64 = 64 << 20

    /// Gives a hold of `key` in `pool`, and loads the model with
    /// ``MLXPooledLoader`` when it is not resident.
    ///
    /// - Parameters:
    ///   - key: One of the models above.
    ///   - pool: The pool of the test.
    /// - Returns: The hold. The model stays resident while the hold exists.
    /// - Throws: What the load throws.
    static func acquire(_ key: ModelPoolKey, in pool: ModelPool) async throws -> ModelHold {
        try await pool.acquire(key, footprintBytes: footprintBytes, sessionBytes: sessionBytes, loader: MLXPooledLoader())
    }
}
