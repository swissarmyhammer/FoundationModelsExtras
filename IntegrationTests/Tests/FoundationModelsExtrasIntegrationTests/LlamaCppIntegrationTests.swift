import FoundationModels
import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import FoundationModelsLlamaCpp
import Testing

/// Qwen3.5-0.8B, Q8_0: one file, the smallest model of the real models of
/// FoundationModelsLlamaCpp, at its pinned revision. It downloads about 900 MB
/// to the default Hugging Face cache.
private let singleFileRef: ModelRef =
    "ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf@807dfd9a6fadbf703207aac3bfb0b2b3040d077c"

/// SmolLM2-135M-Instruct, Q4_0: the split set of the folder `Q4_0`, about
/// 92 MB in three shards, at its pinned revision.
private let splitRef: ModelRef =
    "owalsh/SmolLM2-135M-Instruct-GGUF-Split/Q4_0@b922b4a1802c58a1fffee80de277d0824080430f"

/// The count of the shards of ``splitRef``.
private let splitShardCount = 3

/// The context size that ``splitRef`` loads at.
private let splitContextSize = 4096

/// The prompt of each answer.
private let countingPrompt = "Count from one to twenty in words, separated by commas."

/// The most tokens of each answer.
private let maximumResponseTokens = 128

extension RealModelSuites {
    /// Real GGUF models through the pool: the download of one file from a
    /// path inside a repository, the load, one answer, and speculative
    /// decoding with the MTP layers of the model and with a drafter. A split
    /// set loads from its first shard after the download of each shard. Each
    /// test examines a load of its own, thus it loads its model in a pool of
    /// its own and waits for the eviction of the model.
    @Suite("LlamaCpp loader with real models")
    struct LlamaCppIntegrationTests {
        @Test("a GGUF file of a Hub repository downloads, loads and answers through the pool")
        func answersThroughThePool() async throws {
            let response = try await Self.response(of: ModelPoolKey(ref: singleFileRef, role: .llm))

            #expect(response.outputTokenCount > 0)
        }

        @Test("a model with MTP layers decodes speculatively with no drafter")
        func multiTokenPredictionSpeculates() async throws {
            let response = try await Self.response(of: ModelPoolKey(ref: singleFileRef, role: .llm))

            #expect(try response.metadata["speculativeDecoding"]?.value(Bool.self) == true)
        }

        @Test("a GGUF drafter of the reference drafts for the model")
        func drafterSpeculates() async throws {
            let ref = ModelRef(
                repo: singleFileRef.repo, path: singleFileRef.path, revision: singleFileRef.revision,
                drafter: singleFileRef)

            let response = try await Self.response(of: ModelPoolKey(ref: ref, role: .llm))

            #expect(try response.metadata["speculativeDecoding"]?.value(Bool.self) == true)
            #expect(try #require(try response.metadata["draftedTokenCount"]?.value(Int.self)) > 0)
        }

        @Test("a split set downloads each shard, and measures and answers from its first shard")
        func splitSetLoadsFromItsFirstShard() async throws {
            try ModelAvailability.requireMetalDevice()
            let key = ModelPoolKey(ref: splitRef, role: .llm, contextSize: splitContextSize)
            let pool = Self.makePool()

            let load = try await Self.measureSplitSet(key, in: pool)
            try await IntegrationModels.waitForEviction(of: key, in: pool)

            #expect(load.shardCount == splitShardCount)
            #expect(load.footprint > 0)
            #expect(load.footprint == load.estimate)
            #expect(load.response.outputTokenCount > 0)
        }

        // MARK: Helpers

        /// Makes a pool over the GGUF loader and the default Hugging Face cache.
        ///
        /// - Returns: A new pool.
        private static func makePool() -> ModelPool {
            ModelPool(loader: HubModelLoader(gguf: LlamaCppModelLoader()))
        }

        /// One response of a model: its metadata and the count of its tokens.
        private struct Response {
            /// The metadata of the response entry of the transcript.
            let metadata: [String: GeneratedContent]

            /// The tokens of the reasoning and of the answer.
            let outputTokenCount: Int
        }

        /// What one load of the split set gave.
        private struct SplitSetLoad {
            /// The count of the shards in the cache.
            let shardCount: Int

            /// The bytes that the pool counts for the resident model.
            let footprint: Int64

            /// The bytes that `LlamaLanguageModel.footprintBytes` gives for
            /// the first shard at the context of the hold.
            let estimate: Int64

            /// The response of the model.
            let response: Response
        }

        /// Loads the split set of `key` in `pool`, measures it, and answers
        /// one prompt with it. The hold goes when the call returns.
        ///
        /// - Parameters:
        ///   - key: The key of the split set.
        ///   - pool: The pool of the test.
        /// - Returns: The measures and the response.
        /// - Throws: The error of the load, of the measure, or of the generation.
        private static func measureSplitSet(_ key: ModelPoolKey, in pool: ModelPool) async throws -> SplitSetLoad {
            let hold = try await pool.acquire(key)
            let files = try GGUFSource().cachedFiles(of: key.ref)
            let options = LlamaLanguageModel.Options(contextSize: try #require(hold.key.contextSize))
            let estimate = Int64(try LlamaLanguageModel.footprintBytes(gguf: files.model, options: options))

            let response = try await respond(with: key, in: pool)

            return SplitSetLoad(
                shardCount: files.shards.count, footprint: try #require(pool.footprint.resident[hold.key]),
                estimate: estimate, response: response)
        }

        /// Answers one prompt with the model of `key` in a new pool, and waits
        /// for the eviction of the model.
        ///
        /// - Parameter key: The key of the model.
        /// - Returns: The response.
        /// - Throws: A failed expectation when the machine has no Metal
        ///   device, or the error of the load or of the generation.
        private static func response(of key: ModelPoolKey) async throws -> Response {
            try ModelAvailability.requireMetalDevice()
            let pool = makePool()

            let response = try await respond(with: key, in: pool)
            try await IntegrationModels.waitForEviction(of: key, in: pool)

            return response
        }

        /// Answers one prompt with the model of `key` through `pool`, greedy
        /// and with a bound on the tokens. The model may spend each token on
        /// its reasoning, thus the answer may be empty: the response counts
        /// the tokens of both. The session and its model go when the call
        /// returns.
        ///
        /// - Parameters:
        ///   - key: The key of the model.
        ///   - pool: The pool of the model.
        /// - Returns: The response.
        /// - Throws: The error of the load or of the generation.
        private static func respond(with key: ModelPoolKey, in pool: ModelPool) async throws -> Response {
            let session = LanguageModelSession(
                model: PooledModel(ref: key.ref, pool: pool, contextSize: key.contextSize))

            let answer = try await session.respond(
                to: countingPrompt,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens))

            let entry = try #require(
                session.transcript.compactMap { entry -> Transcript.Response? in
                    if case .response(let response) = entry { response } else { nil }
                }.last)
            return Response(metadata: entry.metadata, outputTokenCount: answer.usage.output.totalTokenCount)
        }
    }
}
