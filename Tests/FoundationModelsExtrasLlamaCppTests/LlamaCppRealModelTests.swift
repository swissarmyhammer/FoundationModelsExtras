import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import FoundationModelsLlamaCpp
import Testing

/// Real GGUF models through the pool: the download of one file from a path
/// inside a repository, the load, one answer, and speculative decoding with
/// the MTP layers of the model and with a drafter. A split set loads from its
/// first shard after the download of each shard. It runs only when
/// `EXTRAS_GGUF_INTEGRATION` is `1`, because it downloads about 900 MB to the
/// default Hugging Face cache and runs the models on Metal.
@Suite(
    "LlamaCpp real model",
    .enabled(if: ProcessInfo.processInfo.environment["EXTRAS_GGUF_INTEGRATION"] == "1", "set EXTRAS_GGUF_INTEGRATION=1"))
struct LlamaCppRealModelTests {
    /// Qwen3.5-0.8B, Q8_0: one file, the smallest model of the real models of
    /// FoundationModelsLlamaCpp, at its pinned revision.
    private static let ref: ModelRef =
        "ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf@807dfd9a6fadbf703207aac3bfb0b2b3040d077c"

    /// SmolLM2-135M-Instruct, Q4_0: the split set of the folder `Q4_0`, about
    /// 92 MB in three shards, at its pinned revision.
    private static let splitRef: ModelRef =
        "owalsh/SmolLM2-135M-Instruct-GGUF-Split/Q4_0@b922b4a1802c58a1fffee80de277d0824080430f"

    /// The count of the shards of ``splitRef``.
    private static let splitShardCount = 3

    /// The context size that ``splitRef`` loads at.
    private static let splitContextSize = 4096

    @Test("a GGUF file of a Hub repository downloads, loads and answers through the pool")
    func answersThroughThePool() async throws {
        let response = try await Self.response(of: Self.ref)

        #expect(response.outputTokenCount > 0)
    }

    @Test("a model with MTP layers decodes speculatively with no drafter")
    func multiTokenPredictionSpeculates() async throws {
        let response = try await Self.response(of: Self.ref)

        #expect(try response.metadata["speculativeDecoding"]?.value(Bool.self) == true)
    }

    @Test("a GGUF drafter of the reference drafts for the model")
    func drafterSpeculates() async throws {
        let ref = ModelRef(repo: Self.ref.repo, path: Self.ref.path, revision: Self.ref.revision, drafter: Self.ref)

        let response = try await Self.response(of: ref)

        #expect(try response.metadata["speculativeDecoding"]?.value(Bool.self) == true)
        #expect(try #require(try response.metadata["draftedTokenCount"]?.value(Int.self)) > 0)
    }

    @Test("a split set downloads each shard, and measures and answers from its first shard")
    func splitSetLoadsFromItsFirstShard() async throws {
        let pool = Self.makePool()
        let hold = try await pool.acquire(
            ModelPoolKey(ref: Self.splitRef, role: .llm, contextSize: Self.splitContextSize))
        let files = try GGUFSource().cachedFiles(of: Self.splitRef)
        let options = LlamaLanguageModel.Options(contextSize: try #require(hold.key.contextSize))
        let estimate = Int64(
            try LlamaLanguageModel.footprintBytes(gguf: files.model, options: options))

        let response = try await Self.response(
            of: Self.splitRef, in: pool, contextSize: Self.splitContextSize)

        let footprint = try #require(pool.footprint.resident[hold.key])
        #expect(files.shards.count == Self.splitShardCount)
        #expect(footprint > 0)
        #expect(footprint == estimate)
        #expect(response.outputTokenCount > 0)
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

    /// Answers one prompt with the model of `ref` through a pool, greedy and
    /// with a bound on the tokens. The model may spend each token on its
    /// reasoning, thus the answer may be empty: the response counts the
    /// tokens of both.
    ///
    /// - Parameters:
    ///   - ref: The reference of the model.
    ///   - pool: The pool of the model. The default is a new pool.
    ///   - contextSize: The context size of the model, or `nil`, the default,
    ///     for the default of the loader.
    /// - Returns: The response.
    private static func response(
        of ref: ModelRef, in pool: ModelPool = makePool(), contextSize: Int? = nil
    ) async throws -> Response {
        let session = LanguageModelSession(
            model: PooledModel(ref: ref, pool: pool, contextSize: contextSize))

        let answer = try await session.respond(
            to: "Count from one to twenty in words, separated by commas.",
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 128))

        let entry = try #require(
            session.transcript.compactMap { entry -> Transcript.Response? in
                guard case .response(let response) = entry else { return nil }
                return response
            }.last)
        return Response(metadata: entry.metadata, outputTokenCount: answer.usage.output.totalTokenCount)
    }
}
