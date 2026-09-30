import FixtureSupport
import Foundation
@testable import FoundationModelsExtras
import HuggingFace
import MLXLMCommon
import Testing

/// The built-in MLX loader measures the weight files of a model in the Hugging
/// Face cache, makes the MLX metal library available to the test binary, and
/// reports the progress of its download.
///
/// Each footprint test builds a small cache in a temporary directory, in the
/// layout of the Hugging Face hub: a ref file, blobs, and a snapshot of links.
/// Each download test uses a fake downloader. No test downloads or loads a
/// model.
///
/// The import is `@testable`, so a test can make a loader over its own cache,
/// call the metal library step, and wrap a fake downloader.
@Suite("MLX model loader: the footprint measure, the metal library and the download progress")
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

    @Test("the download of the MLX loader reports each fraction, then loading, and forwards each progress")
    func downloadReportsEachFractionThenLoading() async throws {
        let reports = Recorder<ModelLoadProgress>()
        let forwarded = Recorder<Double>()
        let downloader = ProgressReportingDownloader(upstream: StepDownloader()) { reports.append($0) }

        _ = try await downloader.download(
            id: Self.repository, revision: MLXModelLoader.defaultRevision, matching: [], useLatest: false
        ) { forwarded.append($0.fractionCompleted) }

        #expect(reports.values == StepDownloader.fractions.map { .downloading(fraction: $0) } + [.loading])
        #expect(forwarded.values == StepDownloader.fractions)
    }

    @Test("a failed download of the MLX loader reports each fraction, and not loading")
    func aFailedDownloadDoesNotReportLoading() async throws {
        let reports = Recorder<ModelLoadProgress>()
        let downloader = ProgressReportingDownloader(upstream: StepDownloader(fails: true)) { reports.append($0) }

        await #expect(throws: FakeLoadError.self) {
            try await downloader.download(
                id: Self.repository, revision: MLXModelLoader.defaultRevision, matching: [], useLatest: false
            ) { _ in }
        }

        #expect(reports.values == StepDownloader.fractions.map { .downloading(fraction: $0) })
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

/// A downloader that downloads nothing: it reports each value of
/// ``fractions`` as a `Progress`, and then returns a folder or throws
/// ``FakeLoadError``.
private struct StepDownloader: Downloader {
    /// The units of work of the fake download.
    private static let totalUnits: Int64 = 4

    /// The units that each report of the fake download completed.
    private static let completedUnits: [Int64] = [1, 3, 4]

    /// The fraction of each report, in order.
    static let fractions = completedUnits.map { Double($0) / Double(totalUnits) }

    /// Whether the download throws ``FakeLoadError`` after its reports.
    private let fails: Bool

    /// Makes a downloader.
    ///
    /// - Parameter fails: Whether the download throws ``FakeLoadError`` after
    ///   its reports.
    init(fails: Bool = false) {
        self.fails = fails
    }

    /// Reports each fraction of ``fractions``, and then returns the temporary
    /// folder or throws.
    ///
    /// - Parameters:
    ///   - id: The repository. The fake does not read it.
    ///   - revision: The revision. The fake does not read it.
    ///   - patterns: The file patterns. The fake does not read them.
    ///   - useLatest: Whether to check for a newer revision. The fake does not
    ///     read it.
    ///   - progressHandler: Gets each report.
    /// - Returns: The temporary folder of the process.
    /// - Throws: ``FakeLoadError`` when ``fails`` is true.
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        for completed in Self.completedUnits {
            let progress = Progress(totalUnitCount: Self.totalUnits)
            progress.completedUnitCount = completed
            progressHandler(progress)
        }
        if fails {
            throw FakeLoadError()
        }
        return FileManager.default.temporaryDirectory
    }
}
