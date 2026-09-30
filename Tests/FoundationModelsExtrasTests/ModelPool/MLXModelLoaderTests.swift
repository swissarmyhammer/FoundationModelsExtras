import FixtureSupport
import Foundation
@testable import FoundationModelsExtras
import HuggingFace
import Testing

/// The built-in MLX loader measures the weight files of a model in the Hugging
/// Face cache, and makes the MLX metal library available to the test binary.
///
/// Each footprint test builds a small cache in a temporary directory, in the
/// layout of the Hugging Face hub: a ref file, blobs, and a snapshot of links.
/// No test downloads or loads a model.
///
/// The import is `@testable`, so a test can make a loader over its own cache
/// and call the metal library step.
@Suite("MLX model loader: the footprint measure and the metal library")
struct MLXModelLoaderTests {
    /// The repository of the key that each test measures.
    private static let repository = "org/model"

    /// The commit that the ref file of the default revision names.
    private static let mainCommit = "0123456789abcdef"

    /// The commit of the pinned revision.
    private static let pinnedCommit = "fedcba9876543210"

    /// The bytes of the first weight file.
    private static let firstWeightBytes = 7

    /// The bytes of the second weight file.
    private static let secondWeightBytes = 5

    /// The bytes of the configuration file, which is not a weight file.
    private static let configurationBytes = 3

    /// The file name of the metal library that MLX looks for beside a binary.
    private static let metalLibraryName = "mlx.metallib"

    /// The folder of the binary of an `.xctest` bundle, relative to the folder
    /// that holds the bundle.
    private static let xctestBinaryPath = "Suite.xctest/Contents/MacOS"

    /// The folder of the library in the Cmlx bundle of SwiftPM, relative to
    /// the folder that holds the bundle.
    private static let bundledLibraryFolder = "mlx-swift_Cmlx.bundle/Contents/Resources"

    /// The file name of the library in the Cmlx bundle.
    private static let bundledLibraryName = "default.metallib"

    /// The bytes of the fake library in the Cmlx bundle.
    private static let bundledLibraryBytes = 4

    @Test("the footprint of a key is the sum of the weight files of the snapshot of the main revision")
    func footprintIsTheSumOfTheWeightFiles() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(in: cache, ref: MLXModelLoader.defaultRevision, commit: Self.mainCommit)
        let loader = MLXModelLoader(cache: cache)

        let bytes = try await loader.footprintBytes(of: ModelPoolKey(ref: ModelRef(Self.repository), role: .llm))

        #expect(bytes == Int64(Self.firstWeightBytes + Self.secondWeightBytes))
    }

    @Test("the footprint of a key that pins a commit is the sum of the weight files of that snapshot")
    func footprintOfAPinnedCommitReadsItsSnapshot() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(in: cache, ref: nil, commit: Self.pinnedCommit)
        let loader = MLXModelLoader(cache: cache)
        let key = ModelPoolKey(ref: ModelRef(repo: Self.repository, revision: Self.pinnedCommit), role: .embedding)

        let bytes = try await loader.footprintBytes(of: key)

        #expect(bytes == Int64(Self.firstWeightBytes + Self.secondWeightBytes))
    }

    @Test("the footprint of a key that the cache does not hold throws notInCache")
    func footprintOfAMissingModelThrows() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = MLXModelLoader(cache: HubCache(cacheDirectory: root))
        let key = ModelPoolKey(ref: ModelRef(Self.repository), role: .llm)

        await #expect(throws: MLXModelLoaderError.notInCache(key: key, revision: MLXModelLoader.defaultRevision)) {
            try await loader.footprintBytes(of: key)
        }
    }

    @Test("the metal library step links mlx.metallib beside an xctest binary to the library of the Cmlx bundle")
    func metalLibraryStepLinksTheBundledLibrary() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let binaryDirectory = try Self.makeDirectory(Self.xctestBinaryPath, in: root)
        let library = try Self.makeDirectory(Self.bundledLibraryFolder, in: root)
            .appendingPathComponent(Self.bundledLibraryName)
        try Data(repeating: 0, count: Self.bundledLibraryBytes).write(to: library)

        try MetalLibraryBootstrap.linkIfMissing(binaryDirectory: binaryDirectory, bundleParentDirectory: root)

        let link = binaryDirectory.appendingPathComponent(Self.metalLibraryName)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == library.path)
    }

    @Test("the metal library step does nothing when no Cmlx bundle is beside the bundle of the binary")
    func metalLibraryStepDoesNothingWithNoBundle() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let binaryDirectory = try Self.makeDirectory(Self.xctestBinaryPath, in: root)

        try MetalLibraryBootstrap.linkIfMissing(binaryDirectory: binaryDirectory, bundleParentDirectory: root)

        let link = binaryDirectory.appendingPathComponent(Self.metalLibraryName)
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    /// Makes the folder at `path` below `root`.
    ///
    /// - Parameters:
    ///   - path: The path of the folder, relative to `root`.
    ///   - root: The folder of the test.
    /// - Returns: The new folder.
    /// - Throws: The error of the folder creation.
    private static func makeDirectory(_ path: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes one snapshot of ``repository`` in `cache`: two weight files and
    /// one configuration file, each a link to a blob.
    ///
    /// - Parameters:
    ///   - cache: The cache to write in.
    ///   - ref: The ref file to write, which names `commit`, or `nil` for no
    ///     ref file.
    ///   - commit: The commit of the snapshot.
    /// - Throws: The error of a file write.
    private static func writeSnapshot(in cache: HubCache, ref: String?, commit: String) throws {
        let repo = try #require(Repo.ID(rawValue: repository))
        if let ref {
            try cache.updateRef(repo: repo, kind: .model, ref: ref, commit: commit)
        }
        let blobs = cache.blobsDirectory(repo: repo, kind: .model)
        let snapshot = try cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        let files = FileManager.default
        try files.createDirectory(at: blobs, withIntermediateDirectories: true)
        try files.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let contents = [
            "model-1.safetensors": firstWeightBytes,
            "model-2.safetensors": secondWeightBytes,
            "config.json": configurationBytes,
        ]
        for (name, byteCount) in contents {
            let blob = blobs.appendingPathComponent("blob-\(name)")
            try Data(repeating: 0, count: byteCount).write(to: blob)
            try files.createSymbolicLink(at: snapshot.appendingPathComponent(name), withDestinationURL: blob)
        }
    }
}
