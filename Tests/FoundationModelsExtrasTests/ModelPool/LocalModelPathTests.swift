import FixtureSupport
import Foundation
import HuggingFace
@testable import FoundationModelsExtras
import Testing

/// A model reference can name a folder on the disk. The Hub loader decides the
/// format of such a folder from its top-level names, and both loaders measure
/// and load the folder with no download.
///
/// Each test uses a small fake model folder in a temporary folder. No test
/// uses the network, and no test loads a model.
@Suite("Local model path: the folder gives the format and the footprint with no download")
struct LocalModelPathTests {
    /// The size of the fake weight file of each format.
    private static let weightBytes = 1024

    // MARK: The reference

    @Test("a reference to an existing folder has that folder as its local directory")
    func existingFolderIsLocal() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ModelRef(repo: root.path).localDirectory?.path == root.path)
    }

    @Test("a Hub repository name has no local directory")
    func hubNameIsNotLocal() {
        #expect(ModelRef(repo: "org/no-such-folder-here").localDirectory == nil)
    }

    @Test("a reference to a file is not a local directory")
    func fileIsNotLocal() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.safetensors")
        try Data().write(to: file)

        #expect(ModelRef(repo: file.path).localDirectory == nil)
    }

    // MARK: The format

    @Test("a local folder with a model package is Core ML")
    func localPackageIsCoreML() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeCoreMLFolder(in: root)

        #expect(try await Self.format(of: root, role: .embedding) == .coreML)
    }

    @Test("a local folder with safetensors weights is MLX")
    func localSafetensorsIsMLX() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeMLXFolder(in: root)

        #expect(try await Self.format(of: root, role: .embedding) == .mlx)
    }

    @Test("a local folder with both formats is MLX")
    func localBothIsMLX() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeCoreMLFolder(in: root)
        try Self.writeMLXFolder(in: root)

        #expect(try await Self.format(of: root, role: .embedding) == .mlx)
    }

    @Test("an llm key of a local folder with a package is MLX")
    func localLLMIsMLX() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeCoreMLFolder(in: root)

        #expect(try await Self.format(of: root, role: .llm) == .mlx)
    }

    // MARK: The footprint

    @Test("the MLX footprint of a local folder is the size of its safetensors files")
    func mlxFootprintOfLocalFolder() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeMLXFolder(in: root)
        let key = ModelPoolKey(ref: ModelRef(repo: root.path), role: .llm)

        let bytes = try await MLXModelLoader(cacheDirectory: Self.emptyCache(in: root)).footprintBytes(of: key)

        #expect(bytes == Int64(Self.weightBytes))
    }

    @Test("the Core ML footprint of a local folder is the size of the weight files of its package")
    func coreMLFootprintOfLocalFolder() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeCoreMLFolder(in: root)
        let key = ModelPoolKey(ref: ModelRef(repo: root.path), role: .embedding)

        let bytes = try await CoreMLModelLoader(cacheDirectory: Self.emptyCache(in: root)).footprintBytes(of: key)

        #expect(bytes == Int64(Self.weightBytes))
    }

    // MARK: The model folder

    @Test("the model folder of a local reference is its local directory")
    func modelFolderOfLocalReference() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = HubSource(cache: HubCache(cacheDirectory: Self.emptyCache(in: root)), tokenProvider: .none)

        #expect(hub.modelFolder(of: ModelRef(repo: root.path), revision: "main")?.path == root.path)
    }

    @Test("the model folder of a Hub reference that the cache lacks is nil")
    func modelFolderOfMissingHubReference() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = HubSource(cache: HubCache(cacheDirectory: Self.emptyCache(in: root)), tokenProvider: .none)

        #expect(hub.modelFolder(of: ModelRef(repo: "org/no-such-model"), revision: "main") == nil)
    }

    @Test("an empty local folder has no format and the Hub loader throws")
    func emptyLocalFolderThrows() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: HubModelLoaderError.unreadableLocalFolder(path: root.path)) {
            try await Self.format(of: root, role: .embedding)
        }
    }

    // MARK: The compiled model

    @Test("the compiled model of a local package gets a new place when its manifest changes")
    func compiledPlaceChangesWithTheManifest() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeCoreMLFolder(in: root)
        let package = root.appendingPathComponent("model.mlpackage", isDirectory: true)
        let manifest = package.appendingPathComponent("Manifest.json")
        let before = try CoreMLPackage.localRevision(of: package)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: manifest.path)

        #expect(try CoreMLPackage.localRevision(of: package) != before)
    }

    @Test("the compiled model of a local package gets a new place when a weight file changes in place")
    func compiledPlaceChangesWithAWeightFile() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeCoreMLFolder(in: root)
        let package = root.appendingPathComponent("model.mlpackage", isDirectory: true)
        let before = try CoreMLPackage.localRevision(of: package)

        try Data(count: Self.weightBytes + 1).write(to: try #require(CoreMLPackage.weightFiles(in: package).first))

        #expect(try CoreMLPackage.localRevision(of: package) != before)
    }

    @Test("the compiled model of a local package gets a new place when only the date of a weight file changes")
    func compiledPlaceChangesWithTheDateOfAWeightFile() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeCoreMLFolder(in: root)
        let package = root.appendingPathComponent("model.mlpackage", isDirectory: true)
        let weight = try #require(CoreMLPackage.weightFiles(in: package).first)
        let before = try CoreMLPackage.localRevision(of: package)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: weight.path)

        #expect(try CoreMLPackage.localRevision(of: package) != before)
    }

    @Test("a file that reports no modification date has no revision line and throws")
    func missingDateThrows() {
        #expect(throws: CoreMLModelLoaderError.unreadablePackage(path: "/model/weight.bin")) {
            try CoreMLPackage.revisionLine(relative: "/weight.bin", size: 4, changed: nil, path: "/model/weight.bin")
        }
    }

    @Test("a file that reports no size has no revision line and throws")
    func missingSizeThrows() {
        #expect(throws: CoreMLModelLoaderError.unreadablePackage(path: "/model/weight.bin")) {
            try CoreMLPackage.revisionLine(relative: "/weight.bin", size: nil, changed: Date(), path: "/model/weight.bin")
        }
    }

    @Test("the compiled model of a package that cannot be read has no place and throws")
    func unreadablePackageThrows() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("missing.mlpackage", isDirectory: true)

        #expect(throws: CoreMLModelLoaderError.unreadablePackage(path: package.path)) {
            try CoreMLPackage.localRevision(of: package)
        }
    }

    // MARK: Helpers

    /// Decides the format of the local folder `folder` with a Hub loader whose
    /// cache is empty, thus a Hub lookup would fail.
    private static func format(of folder: URL, role: ModelRole) async throws -> HubModelFormat {
        let loader = HubModelLoader(cacheDirectory: emptyCache(in: folder))
        return try await loader.format(of: ModelPoolKey(ref: ModelRef(repo: folder.path), role: role))
    }

    /// A cache folder that does not exist, beside `folder`.
    private static func emptyCache(in folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent("no-cache-\(UUID().uuidString)", isDirectory: true)
    }

    /// Writes a Core ML model folder: a package with a manifest and one weight
    /// file, and a tokenizer file.
    private static func writeCoreMLFolder(in root: URL) throws {
        let files = FileManager.default
        let weights = root.appendingPathComponent("model.mlpackage/Data/com.apple.CoreML/weights", isDirectory: true)
        try files.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("model.mlpackage/Manifest.json"))
        try Data(count: weightBytes).write(to: weights.appendingPathComponent("weight.bin"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
    }

    /// Writes an MLX model folder: one weight file and a config.
    private static func writeMLXFolder(in root: URL) throws {
        try Data(count: weightBytes).write(to: root.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
    }
}
