import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import Testing

/// One real GGUF model through the pool: the download of one file from a path
/// inside a repository, the load, one answer, and speculative decoding with
/// the MTP layers of the model and with a drafter. It runs only when
/// `EXTRAS_GGUF_INTEGRATION` is `1`, because it downloads about 800 MB to the
/// default Hugging Face cache and runs the model on Metal.
@Suite(
    "LlamaCpp real model",
    .enabled(if: ProcessInfo.processInfo.environment["EXTRAS_GGUF_INTEGRATION"] == "1", "set EXTRAS_GGUF_INTEGRATION=1"))
struct LlamaCppRealModelTests {
    /// Qwen3.5-0.8B, Q8_0: one file, the smallest model of the real models of
    /// FoundationModelsLlamaCpp, at its pinned revision.
    private static let ref: ModelRef =
        "ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf@807dfd9a6fadbf703207aac3bfb0b2b3040d077c"

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

    // MARK: Helpers

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
    /// - Parameter ref: The reference of the model.
    /// - Returns: The response.
    private static func response(of ref: ModelRef) async throws -> Response {
        let pool = ModelPool(loader: HubModelLoader(gguf: LlamaCppModelLoader()))
        let session = LanguageModelSession(model: PooledModel(ref: ref, pool: pool))

        let answer = try await session.respond(
            to: "Count from one to twenty in words, separated by commas.",
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 128))

        let entry = try #require(
            session.transcript.compactMap { entry -> Transcript.Response? in
                guard case .response(let response) = entry else { return nil }
                return response
            }.last)
        return Response(metadata: entry.metadata, outputTokenCount: answer.usage.output.totalTokenCount)
    }
}
