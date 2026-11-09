import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import Testing

/// One real GGUF model through the pool: the download of one file from a path
/// inside a repository, the load, and one answer. It runs only when
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
        let pool = ModelPool(loader: HubModelLoader(gguf: LlamaCppModelLoader()))
        let session = LanguageModelSession(model: PooledModel(ref: Self.ref, pool: pool))

        let answer = try await session.respond(to: "Reply with the one word: blue")

        #expect(!answer.content.isEmpty)
    }
}
