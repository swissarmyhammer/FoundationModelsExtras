import FixtureSupport
import Foundation
@testable import FoundationModelsExtras
import HuggingFace
import Testing

/// The Hub loader picks the loader of a model from the format of its files:
/// `safetensors` weights go to MLX, and a `.mlpackage` folder goes to Core ML.
///
/// Each test uses a path list, or a small fake snapshot in a temporary folder.
/// No test uses the network, and no test loads a model.
@Suite("Hub model loader: the format of the files picks MLX or Core ML")
struct HubModelLoaderTests {
    /// The repository of the key that each test uses.
    private static let repository = "org/some-model"

    /// The commit of the snapshot of the fake cache.
    private static let commit = "0123456789abcdef"

    // MARK: Format of a path list

    @Test("a repository with a model package and no safetensors file is Core ML")
    func packageOnlyIsCoreML() {
        let paths = [
            "model-8bit.mlpackage/Manifest.json",
            "model-8bit.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            "tokenizer.json",
        ]

        #expect(HubModelFormat.detect(paths: paths) == .coreML)
    }

    @Test("the folder of a package alone, with no file path below it, is Core ML")
    func packageFolderAloneIsCoreML() {
        #expect(HubModelFormat.detect(paths: ["model.mlpackage", "tokenizer.json"]) == .coreML)
    }

    @Test("a repository with safetensors weights is MLX")
    func safetensorsIsMLX() {
        let paths = ["config.json", "model.safetensors", "tokenizer.json"]

        #expect(HubModelFormat.detect(paths: paths) == .mlx)
    }

    @Test("a repository with both formats is MLX, because MLX loads each role")
    func bothFormatsIsMLX() {
        let paths = ["model.mlpackage/Manifest.json", "weights/model-00001.safetensors"]

        #expect(HubModelFormat.detect(paths: paths) == .mlx)
    }

    @Test("a repository with neither format is MLX, thus the MLX loader names the missing files")
    func neitherFormatIsMLX() {
        #expect(HubModelFormat.detect(paths: ["README.md", "config.json"]) == .mlx)
        #expect(HubModelFormat.detect(paths: []) == .mlx)
    }

    @Test("a repository with only a compiled mlmodelc folder is MLX, because the Core ML loader compiles a package itself")
    func compiledFolderAloneIsMLX() {
        let paths = ["model.mlmodelc/coremldata.bin", "model.mlmodelc/weights/weight.bin", "tokenizer.json"]

        #expect(HubModelFormat.detect(paths: paths) == .mlx)
    }

    @Test("a repository with GGUF files and no safetensors file is GGUF")
    func ggufIsGGUF() {
        #expect(HubModelFormat.detect(paths: ["Q4_K_M/model-Q4_K_M.gguf", "README.md"]) == .gguf)
    }

    @Test("a repository with the shards of a split set and no other GGUF file is GGUF")
    func splitSetIsGGUF() {
        let paths = [
            "Q4_0/model-Q4_0-00001-of-00002.gguf", "Q4_0/model-Q4_0-00002-of-00002.gguf", "README.md",
        ]

        #expect(HubModelFormat.detect(paths: paths) == .gguf)
    }

    @Test("a repository with GGUF files and safetensors weights is MLX")
    func ggufAndSafetensorsIsMLX() {
        #expect(HubModelFormat.detect(paths: ["model.gguf", "model.safetensors"]) == .mlx)
    }

    @Test("an image projector alone does not make a repository GGUF")
    func projectorAloneIsNotGGUF() {
        #expect(HubModelFormat.detect(paths: ["mmproj-F16.gguf"]) == .mlx)
    }

    @Test("a name that only contains the text mlpackage is not a package")
    func lookalikeNameIsNotAPackage() {
        #expect(HubModelFormat.detect(paths: ["my-mlpackage-notes.md", "mlpackage"]) == .mlx)
    }

    // MARK: Format of a cached snapshot

    @Test("an embedding key whose cached snapshot holds a package is Core ML, with no network")
    func cachedPackageIsCoreML() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = HubModelLoader(cacheDirectory: root)
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.mlpackage/Manifest.json"])

        let format = try await loader.format(of: Self.key(.embedding))

        #expect(format == .coreML)
    }

    @Test("an embedding key whose cached snapshot holds safetensors is MLX, with no network")
    func cachedSafetensorsIsMLX() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = HubModelLoader(cacheDirectory: root)
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.safetensors", "config.json"])

        let format = try await loader.format(of: Self.key(.embedding))

        #expect(format == .mlx)
    }

    @Test("an llm key is MLX when the cached snapshot holds a package, and needs no network")
    func llmKeyOfAPackageIsMLX() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = HubModelLoader(cacheDirectory: root)
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.mlpackage/Manifest.json"])

        let format = try await loader.format(of: Self.key(.llm))

        #expect(format == .mlx)
    }

    @Test("an llm key whose cached snapshot holds a GGUF file under the path of the reference is GGUF")
    func cachedGGUFUnderThePathIsGGUF() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = HubModelLoader(cacheDirectory: root)
        try Self.writeSnapshot(
            in: HubCache(cacheDirectory: root), paths: ["Q4_K_M/model-Q4_K_M.gguf", "model.safetensors"])

        let format = try await loader.format(of: Self.key(.llm, path: "Q4_K_M"))

        #expect(format == .gguf)
    }

    @Test("a reference with a path to MLX files fails, because only GGUF loads from a path")
    func pathToMLXFails() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = HubModelLoader(cacheDirectory: root)
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["sub/model.safetensors"])
        let key = Self.key(.llm, path: "sub")

        await #expect(throws: HubModelLoaderError.pathNeedsGGUF(ref: key.ref.stringValue)) {
            try await loader.format(of: key)
        }
    }

    @Test("a local reference to a GGUF file is GGUF")
    func localGGUFFileIsGGUF() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        try Data().write(to: file)

        let format = try await HubModelLoader(cacheDirectory: root).format(
            of: ModelPoolKey(ref: ModelRef(file.path), role: .llm))

        #expect(format == .gguf)
    }

    @Test("a local reference to nothing on the disk fails, and names the location")
    func missingLocalReferenceFails() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("no-such-model").path

        await #expect(throws: HubModelLoaderError.missingLocalModel(path: missing)) {
            try await HubModelLoader(cacheDirectory: root).format(of: ModelPoolKey(ref: ModelRef(missing), role: .llm))
        }
    }

    // MARK: The GGUF loader

    @Test("a GGUF model with no GGUF loader fails with an error that names the product")
    func ggufWithNoLoaderFails() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.gguf"])
        let loader = HubModelLoader(cacheDirectory: root)

        let error = await #expect(throws: HubModelLoaderError.noGGUFLoader) {
            try await loader.load(Self.key(.llm))
        }
        #expect(error?.errorDescription?.contains("FoundationModelsExtrasLlamaCpp") == true)
    }

    @Test("a GGUF model loads, measures and evicts with the GGUF loader")
    func ggufGoesToTheGGUFLoader() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.gguf"])
        let gguf = RecordingLoader()
        let loader = HubModelLoader(cacheDirectory: root, gguf: gguf)

        let container = try await loader.load(Self.key(.llm))
        let bytes = try await loader.footprintBytes(of: Self.key(.llm))
        await loader.evict(container)

        #expect(container as? String == RecordingLoader.container)
        #expect(bytes == RecordingLoader.footprint)
        #expect(gguf.loadedKeys == [Self.key(.llm)])
        #expect(gguf.evictedCount == 1)
    }

    // MARK: The pool key

    @Test("the pool key of an MLX model drops the context")
    func mlxPoolKeyDropsTheContext() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.safetensors", "config.json"])
        let gguf = RecordingLoader()
        let loader = HubModelLoader(cacheDirectory: root, gguf: gguf)

        let key = try await loader.poolKey(for: Self.key(.llm, contextSize: 8192))

        #expect(key == Self.key(.llm))
        #expect(gguf.poolKeyRequests.isEmpty)
    }

    @Test("the pool key of a GGUF model is the key that the GGUF loader gives")
    func ggufPoolKeyKeepsTheContext() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.gguf"])
        let gguf = RecordingLoader()
        let loader = HubModelLoader(cacheDirectory: root, gguf: gguf)

        let key = try await loader.poolKey(for: Self.key(.llm, contextSize: 8192))

        #expect(key == Self.key(.llm, contextSize: 8192))
        #expect(gguf.poolKeyRequests == [Self.key(.llm, contextSize: 8192)])
    }

    @Test("a key with no context needs no format, thus reads no file")
    func noContextReadsNoFile() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = ModelPoolKey(ref: ModelRef(root.appendingPathComponent("no-such-model").path), role: .llm)

        let key = try await HubModelLoader(cacheDirectory: root).poolKey(for: missing)

        #expect(key == missing)
    }

    @Test("a key whose format fails stays as it is, thus the load throws the error")
    func failedFormatKeepsTheKey() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("no-such-model").path
        let missing = ModelPoolKey(ref: ModelRef(path), role: .llm, contextSize: 8192)
        let loader = HubModelLoader(cacheDirectory: root)

        let key = try await loader.poolKey(for: missing)

        #expect(key == missing)
        await #expect(throws: HubModelLoaderError.missingLocalModel(path: path)) {
            try await loader.load(key)
        }
    }

    @Test("the format of the pool key is decided one time for each model")
    func poolKeyFormatIsCached() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(in: cache, paths: ["model.gguf"])
        let loader = HubModelLoader(cacheDirectory: root, gguf: RecordingLoader())
        _ = try await loader.poolKey(for: Self.key(.llm, contextSize: 8192))
        try FileManager.default.removeItem(at: root.appendingPathComponent("models--org--some-model"))

        let key = try await loader.poolKey(for: Self.key(.llm, contextSize: 16384))

        #expect(key == Self.key(.llm, contextSize: 16384))
    }

    // MARK: The default of the pool

    @Test("a reference with a revision reads the snapshot of that revision")
    func revisionPicksItsOwnSnapshot() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(in: cache, paths: ["model.mlpackage/Manifest.json"], ref: "pinned")
        let loader = HubModelLoader(cacheDirectory: root)
        let pinned = ModelPoolKey(ref: ModelRef(repo: Self.repository, revision: "pinned"), role: .embedding)

        let format = try await loader.format(of: pinned)

        #expect(format == .coreML)
    }

    // MARK: Helpers

    /// Makes the key of ``repository`` in `role`, with the path inside the
    /// repository.
    private static func key(_ role: ModelRole, path: String? = nil, contextSize: Int? = nil) -> ModelPoolKey {
        ModelPoolKey(ref: ModelRef(repo: repository, path: path), role: role, contextSize: contextSize)
    }

    /// A GGUF loader that records each call and loads nothing.
    private final class RecordingLoader: PooledModelLoader, @unchecked Sendable {
        /// The container of each load.
        static let container = "gguf container"

        /// The footprint of each model.
        static let footprint: Int64 = 42

        /// The lock of the records.
        private let lock = NSLock()

        /// The keys of each load, in order.
        private var keys: [ModelPoolKey] = []

        /// The number of evictions.
        private var evictions = 0

        /// The keys of each load, in order.
        var loadedKeys: [ModelPoolKey] { lock.withLock { keys } }

        /// The number of evictions.
        var evictedCount: Int { lock.withLock { evictions } }

        /// The keys of each pool key request, in order.
        private var poolKeys: [ModelPoolKey] = []

        /// The keys of each pool key request, in order.
        var poolKeyRequests: [ModelPoolKey] { lock.withLock { poolKeys } }

        func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey {
            lock.withLock { poolKeys.append(key) }
            return key
        }

        func load(_ key: ModelPoolKey) async throws -> any Sendable {
            lock.withLock { keys.append(key) }
            return Self.container
        }

        func evict(_ container: any Sendable) async {
            lock.withLock { evictions += 1 }
        }

        func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
            Self.footprint
        }
    }

    /// Writes one snapshot of ``repository`` in `cache`, with one empty file
    /// for each path.
    ///
    /// - Parameters:
    ///   - cache: The cache to write in.
    ///   - paths: The paths of the files of the snapshot.
    ///   - ref: The ref file to write, which names ``commit``. The default is
    ///     `main`.
    /// - Throws: The error of a file write.
    private static func writeSnapshot(in cache: HubCache, paths: [String], ref: String = "main") throws {
        let repo = try #require(Repo.ID(rawValue: repository))
        try cache.updateRef(repo: repo, kind: .model, ref: ref, commit: commit)
        let blobs = cache.blobsDirectory(repo: repo, kind: .model)
        let snapshot = try cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        let files = FileManager.default
        try files.createDirectory(at: blobs, withIntermediateDirectories: true)
        for path in paths {
            let blob = blobs.appendingPathComponent("blob-\(path.replacingOccurrences(of: "/", with: "-"))")
            try Data().write(to: blob)
            let link = snapshot.appendingPathComponent(path)
            try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: link, withDestinationURL: blob)
        }
    }
}
