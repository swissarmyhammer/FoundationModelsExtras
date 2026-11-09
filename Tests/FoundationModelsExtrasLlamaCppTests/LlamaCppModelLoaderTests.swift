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

    @Test("the footprint is the size of each shard")
    func footprintIsTheSizeOfTheFiles() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Q8_0", isDirectory: true)
        let first = try Self.copyVocabulary(to: folder, as: "m-00001-of-00002.gguf")
        let second = try Self.copyVocabulary(to: folder, as: "m-00002-of-00002.gguf")
        let expected = try [first, second].reduce(Int64(0)) { total, file in
            total + Int64(try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        }

        let bytes = try await LlamaCppModelLoader(cacheDirectory: root).footprintBytes(of: Self.key(folder.path, .llm))

        #expect(bytes == expected)
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

    @Test("a reference with a drafter is refused until the GGUF drafter lands")
    func drafterIsRefused() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try Self.copyVocabulary(to: root, as: "model.gguf")
        let ref = ModelRef(repo: model.path, drafter: ModelRef(model.path))

        await #expect(throws: LlamaCppModelLoaderError.drafterNotSupported(ref: ref.stringValue)) {
            try await LlamaCppModelLoader(cacheDirectory: root).load(ModelPoolKey(ref: ref, role: .llm))
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
