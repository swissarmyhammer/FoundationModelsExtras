import FoundationModelsExtras
import Testing

/// The real models of this suite, in one place.
///
/// These are small models that the FoundationModelsRouter integration suite
/// also loads, thus the model cache of the CI runner holds them already.
enum IntegrationModels {
    /// A small instruct LLM, about 0.7 GB of weights.
    static let llm = ModelPoolKey(ref: "mlx-community/Llama-3.2-1B-Instruct-4bit", role: .llm)

    /// A small embedding model, about 0.3 GB of weights.
    static let embedding = ModelPoolKey(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", role: .embedding)

    /// A 4B instruct LLM that calls tools, about 2.3 GB of weights.
    ///
    /// The tool-hosting suite uses it, because the 1B ``llm`` does not call
    /// tools reliably. The FoundationModelsRouter tool-answer suite loads the
    /// same model for the same reason, thus the model cache of the CI runner
    /// holds it already.
    static let toolCallingLLM = ModelPoolKey(ref: "mlx-community/Qwen3-4B-4bit", role: .llm)

    /// The bytes that the pool counts for the weights and one session of each
    /// model. This is a rough upper limit for ``llm`` and ``embedding``.
    static let footprintBytes: Int64 = 1 << 30

    /// The bytes that the pool counts for the weights and one session of
    /// ``toolCallingLLM``. This is a rough upper limit.
    static let toolCallingFootprintBytes: Int64 = 3 << 30

    /// The bytes that the pool counts for the session of each hold.
    static let sessionBytes: Int64 = 64 << 20

    /// Gives a hold of `key` in `pool`, and loads the model with `loader` when
    /// it is not resident.
    ///
    /// - Parameters:
    ///   - key: One of the models above.
    ///   - pool: The pool of the test.
    ///   - loader: The loader of the model. The default is ``MLXPooledLoader``.
    ///   - footprint: The bytes that the pool counts for the weights and one
    ///     session of the model. The default is ``footprintBytes``.
    /// - Returns: The hold. The model stays resident while the hold exists.
    /// - Throws: What the load throws.
    static func acquire(
        key: ModelPoolKey,
        in pool: ModelPool,
        loader: any PooledModelLoader = MLXPooledLoader(),
        footprint: Int64 = footprintBytes
    ) async throws -> ModelHold {
        try await pool.acquire(key, footprintBytes: footprint, sessionBytes: sessionBytes, loader: loader)
    }

    /// The length of each vector of the embedding model of `hold`, as its
    /// container reports it. A `PooledEmbedder` has no dimension, because the
    /// dimension is not known before the load.
    ///
    /// - Parameter hold: A hold of an embedding model.
    /// - Returns: The dimension of the container.
    /// - Throws: An `ExpectationFailedError` when the container is not a
    ///   `PooledEmbedding`.
    static func embeddingDimension(of hold: ModelHold) throws -> Int {
        try #require(hold.container as? any PooledEmbedding).dimension
    }

    /// Waits until `key` is not resident in `pool`, and until the eviction job
    /// of `key` ended. The release of the last hold starts the eviction job,
    /// which runs after the release returns.
    ///
    /// Each test waits for the eviction of each model that it loaded. The
    /// weights of an `MLXLanguageModel` are in one model cache for each
    /// process, thus a late eviction job of one test removes the weights under
    /// the hold of the next test.
    ///
    /// The memory of a model is free only after the evict call of its loader
    /// returns. `MLXLanguageModel.evict()` frees the prompt cache of the model
    /// in that call, and on 2026-09-29 about 370 MB of the last generation
    /// test was still active when the footprint showed no LLM. The memory
    /// check of the next test then read too much memory before its load. The
    /// pool now counts an evicted model until its evict call returns, thus a
    /// footprint without the key shows that the call returned. This wait also
    /// runs an empty admission job: the last release puts the eviction job in
    /// the admission queue in the same step, and the queue runs its jobs first
    /// in first out, thus the empty job starts only after the eviction job
    /// ended.
    ///
    /// - Parameters:
    ///   - key: A model of `pool` that has no hold.
    ///   - pool: The pool of the test.
    /// - Throws: `CancellationError` when the task is cancelled, for example
    ///   by the time limit.
    static func waitForEviction(of key: ModelPoolKey, in pool: ModelPool) async throws {
        for await footprint in pool.footprints where footprint.resident[key] == nil {
            break
        }
        try await pool.admit { _ in }
    }
}
