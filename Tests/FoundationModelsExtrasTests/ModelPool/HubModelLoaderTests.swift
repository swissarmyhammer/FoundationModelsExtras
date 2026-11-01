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

    @Test("an llm key is MLX, also when the cached snapshot holds a package, and needs no network")
    func llmKeyIsAlwaysMLX() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = HubModelLoader(cacheDirectory: root)
        try Self.writeSnapshot(in: HubCache(cacheDirectory: root), paths: ["model.mlpackage/Manifest.json"])

        let format = try await loader.format(of: Self.key(.llm))

        #expect(format == .mlx)
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

    /// Makes the key of ``repository`` in `role`.
    private static func key(_ role: ModelRole) -> ModelPoolKey {
        ModelPoolKey(ref: ModelRef(repo: repository), role: role)
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
