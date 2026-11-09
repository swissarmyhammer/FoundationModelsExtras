import FixtureSupport
import Foundation
import FoundationModelsExtras
import FoundationModelsExtrasLlamaCpp
import FoundationModelsLlamaCpp
import LlamaCppTestFixtures
import Testing

/// ``LlamaCppModelLoader``: a GGUF model of the pool loads as a
/// `LlamaLanguageModel`. Each test uses a vocab-only GGUF file of
/// `LlamaCppTestFixtures` in a temporary folder. The initializer of the model
/// reads the metadata only, thus no test loads weights or uses the network.
@Suite("LlamaCpp model loader: a GGUF model loads as a LlamaLanguageModel")
struct LlamaCppModelLoaderTests {
    /// The vocab-only GGUF file of the tests.
    private static let vocabulary = "qwen35"

    /// A context that is not the default of the options.
    private static let loadedContext = 16384

    @Test("an llm key of a local GGUF file loads a LlamaLanguageModel")
    func loadsALlamaLanguageModel() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try Self.copyVocabulary(to: root, as: "model.gguf")

        let container = try await LlamaCppModelLoader(cacheDirectory: root).load(Self.key(model.path, .llm))

        #expect(container is LlamaLanguageModel)
    }

    @Test("a local folder loads through HubModelLoader with the GGUF loader")
    func loadsThroughTheHubLoader() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Q8_0", isDirectory: true)
        try Self.copyVocabulary(to: folder, as: "model-Q8_0.gguf")
        let loader = HubModelLoader(cacheDirectory: root, gguf: LlamaCppModelLoader(cacheDirectory: root))

        let container = try await loader.load(Self.key(folder.path, .llm))

        #expect(container is LlamaLanguageModel)
    }

    @Test("the footprint is the llama.cpp estimate of every shard of the model")
    func footprintIsTheLlamaEstimate() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Q8_0", isDirectory: true)
        let first = try Self.copyVocabulary(to: folder, as: "m-00001-of-00002.gguf")
        try Self.copyVocabulary(to: folder, as: "m-00002-of-00002.gguf")
        let expected = Int64(try LlamaLanguageModel.footprintBytes(gguf: first))

        let bytes = try await LlamaCppModelLoader(cacheDirectory: root).footprintBytes(of: Self.key(folder.path, .llm))

        #expect(bytes == expected)
    }

    @Test("the footprint of a model with a drafter counts the drafter")
    func footprintCountsTheDrafter() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try Self.copyVocabulary(to: root.appendingPathComponent("target"), as: "model.gguf")
        let drafter = try Self.copyVocabulary(to: root.appendingPathComponent("drafter"), as: "drafter.gguf")
        let ref = ModelRef(repo: model.path, drafter: ModelRef(drafter.path))
        let expected = Int64(try LlamaLanguageModel.footprintBytes(gguf: model, drafter: drafter))

        let bytes = try await LlamaCppModelLoader(cacheDirectory: root).footprintBytes(of: ModelPoolKey(ref: ref, role: .llm))

        #expect(bytes == expected)
        #expect(bytes > Int64(try LlamaLanguageModel.footprintBytes(gguf: model)))
    }

    @Test("the pool key keeps the context, and a key with none gets the context of the options")
    func poolKeyContext() async throws {
        let loader = LlamaCppModelLoader(options: LlamaLanguageModel.Options(contextSize: 8192))
        let ref: ModelRef = "org/model-GGUF"

        let explicit = try await loader.poolKey(for: ModelPoolKey(ref: ref, role: .llm, contextSize: 16384))
        let implicit = try await loader.poolKey(for: ModelPoolKey(ref: ref, role: .llm))

        #expect(explicit.contextSize == 16384)
        #expect(implicit.contextSize == 8192)
        #expect(loader.options.contextSize == 8192)
    }

    @Test("a key with a context loads and measures at that context")
    func loadsAtTheContextOfTheKey() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try Self.copyVocabulary(to: root, as: "model.gguf")
        let loader = LlamaCppModelLoader(cacheDirectory: root)
        let key = ModelPoolKey(ref: ModelRef(model.path), role: .llm, contextSize: Self.loadedContext)
        let expected = try LlamaLanguageModel.footprintBytes(
            gguf: model, options: LlamaLanguageModel.Options(contextSize: Self.loadedContext))

        let container = try await loader.load(key)
        let bytes = try await loader.footprintBytes(of: key)

        #expect((container as? LlamaLanguageModel)?.contextSize == Self.loadedContext)
        #expect(bytes == Int64(expected))
        #expect(bytes != (try await loader.footprintBytes(of: key.withoutContext)))
    }

    @Test("an embedding key is refused")
    func embeddingIsRefused() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try Self.copyVocabulary(to: root, as: "model.gguf")

        await #expect(throws: LlamaCppModelLoaderError.unsupportedRole(.embedding)) {
            try await LlamaCppModelLoader(cacheDirectory: root).load(Self.key(model.path, .embedding))
        }
    }

    @Test("a local GGUF drafter in a folder loads with the model")
    func drafterLoads() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try Self.copyVocabulary(to: root.appendingPathComponent("target"), as: "model.gguf")
        let folder = root.appendingPathComponent("drafter", isDirectory: true)
        try Self.copyVocabulary(to: folder, as: "drafter-Q8_0.gguf")
        let ref = ModelRef(repo: model.path, drafter: ModelRef(folder.path))

        let container = try await LlamaCppModelLoader(cacheDirectory: root).load(ModelPoolKey(ref: ref, role: .llm))

        #expect(container is LlamaLanguageModel)
    }

    @Test("a drafter that holds no GGUF model is refused")
    func drafterThatIsNotGGUFIsRefused() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try Self.copyVocabulary(to: root.appendingPathComponent("target"), as: "model.gguf")
        let folder = root.appendingPathComponent("mlx-drafter", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 16).write(to: folder.appendingPathComponent("model.safetensors"))
        let drafter = ModelRef(folder.path)
        let ref = ModelRef(repo: model.path, drafter: drafter)

        await #expect(throws: LlamaCppModelLoaderError.drafterNotGGUF(ref: drafter.stringValue)) {
            try await LlamaCppModelLoader(cacheDirectory: root).load(ModelPoolKey(ref: ref, role: .llm))
        }
        await #expect(throws: LlamaCppModelLoaderError.drafterNotGGUF(ref: drafter.stringValue)) {
            try await LlamaCppModelLoader(cacheDirectory: root).footprintBytes(of: ModelPoolKey(ref: ref, role: .llm))
        }
    }

    // MARK: Helpers

    /// The key of the reference `text` in `role`.
    private static func key(_ text: String, _ role: ModelRole) -> ModelPoolKey {
        ModelPoolKey(ref: ModelRef(text), role: role)
    }

    /// Copies the vocab-only GGUF file to `folder` with the name `name`.
    ///
    /// - Returns: The copy.
    @discardableResult
    private static func copyVocabulary(to folder: URL, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(
            at: LlamaCppTestFixtures.vocabURL(named: vocabulary).resolvingSymlinksInPath(), to: copy)
        return copy
    }
}
