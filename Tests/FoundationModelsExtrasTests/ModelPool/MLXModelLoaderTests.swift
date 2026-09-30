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

    @Test(
        "the download reports the completed and total bytes of the repository, with the part of a file that downloads now, then loading"
    )
    func downloadReportsTheBytesOfEachStepThenLoading() async throws {
        let steps: [SnapshotStep] = [.noBytes, .partOfFirstFile, .firstFileAndPartOfSecond, .allBytes]
        let forwarded = Recorder<Double>()

        let reports = try await Self.reports(of: StepDownloader(steps: steps)) { forwarded.append($0.fractionCompleted) }

        #expect(reports == steps.map(\.download) + [.loading])
        #expect(forwarded.values == steps.map(\.fraction))
    }

    @Test("a failed download reports its bytes, and not loading")
    func aFailedDownloadDoesNotReportLoading() async throws {
        let steps: [SnapshotStep] = [.noBytes, .partOfFirstFile]
        let reports = Recorder<ModelLoadProgress>()
        let downloader = ProgressReportingDownloader(upstream: StepDownloader(steps: steps, fails: true)) {
            reports.append($0)
        }

        await #expect(throws: FakeLoadError.self) {
            try await downloader.download(
                id: Self.repository, revision: MLXModelLoader.defaultRevision, matching: [], useLatest: false
            ) { _ in }
        }

        #expect(reports.values == steps.map(\.download))
    }

    @Test("the download reports each byte count one time, and never fewer completed bytes than before")
    func downloadReportsNoSmallerOrRepeatedByteCount() async throws {
        let steps: [SnapshotStep] = [.firstFileAndPartOfSecond, .partOfFirstFile, .firstFileAndPartOfSecond, .allBytes]

        let reports = try await Self.reports(of: StepDownloader(steps: steps)) { _ in }

        #expect(reports == [SnapshotStep.firstFileAndPartOfSecond.download, SnapshotStep.allBytes.download, .loading])
    }

    @Test("a download that returns before a report of all its bytes reports all its bytes, then loading")
    func downloadThatReturnsEarlyReportsAllItsBytes() async throws {
        let steps: [SnapshotStep] = [.noBytes, .partOfFirstFile]

        let reports = try await Self.reports(of: StepDownloader(steps: steps)) { _ in }

        #expect(reports == steps.map(\.download) + [SnapshotStep.allBytes.download, .loading])
    }

    @Test("a download whose first report is complete downloaded nothing, and reports only loading")
    func aCachedDownloadReportsOnlyLoading() async throws {
        let reports = try await Self.reports(of: StepDownloader(steps: [.allBytes])) { _ in }

        #expect(reports == [.loading])
    }

    /// Downloads with a ``ProgressReportingDownloader`` over `upstream`.
    ///
    /// - Parameters:
    ///   - upstream: The fake downloader.
    ///   - progressHandler: Gets each progress that the downloader forwards.
    /// - Returns: The reports of the downloader, in order.
    /// - Throws: The error of `upstream`.
    private static func reports(
        of upstream: StepDownloader, forwardingTo progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> [ModelLoadProgress] {
        let reports = Recorder<ModelLoadProgress>()
        let downloader = ProgressReportingDownloader(upstream: upstream) { reports.append($0) }
        _ = try await downloader.download(
            id: repository, revision: MLXModelLoader.defaultRevision, matching: [], useLatest: false,
            progressHandler: progressHandler)
        return reports.values
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

/// One report of a fake snapshot download of two files: the completed bytes
/// of each file.
///
/// The step makes its `Progress` as the Hugging Face downloader does: a parent
/// that counts the bytes of all files, with one child for each file. The
/// parent counts the bytes of a child in its `completedUnitCount` only when
/// the child ends. The bytes of a file that downloads now show only in the
/// `fractionCompleted` of the parent.
private struct SnapshotStep: Sendable {
    /// The bytes of the first file of the fake snapshot.
    private static let firstFileBytes: Int64 = 300

    /// The bytes of the second file of the fake snapshot.
    private static let secondFileBytes: Int64 = 100

    /// The completed bytes of the first file in a step that downloads it now.
    private static let halfOfFirstFile: Int64 = 150

    /// The completed bytes of the second file in a step that downloads it now.
    private static let halfOfSecondFile: Int64 = 50

    /// The bytes of each file of the fake snapshot, in order.
    private static let fileBytes = [firstFileBytes, secondFileBytes]

    /// The bytes of all files of the fake snapshot.
    static let totalBytes = fileBytes.reduce(0, +)

    /// No file has bytes.
    static let noBytes = SnapshotStep(completedFileBytes: [0, 0])

    /// A part of the first file downloaded, and no file ended.
    static let partOfFirstFile = SnapshotStep(completedFileBytes: [halfOfFirstFile, 0])

    /// The first file ended, and a part of the second file downloaded.
    static let firstFileAndPartOfSecond = SnapshotStep(completedFileBytes: [firstFileBytes, halfOfSecondFile])

    /// All files ended.
    static let allBytes = SnapshotStep(completedFileBytes: fileBytes)

    /// The completed bytes of each file, in the order of ``fileBytes``.
    let completedFileBytes: [Int64]

    /// The completed bytes of all files.
    var completedBytes: Int64 { completedFileBytes.reduce(0, +) }

    /// The report of this step that the downloader must give.
    var download: ModelLoadProgress { .downloading(completedBytes: completedBytes, totalBytes: Self.totalBytes) }

    /// The part of the snapshot that this step completed.
    var fraction: Double { Double(completedBytes) / Double(Self.totalBytes) }

    /// Makes the `Progress` of this step, and gives it to `progressHandler`.
    ///
    /// - Parameter progressHandler: Gets the progress.
    func report(to progressHandler: (Progress) -> Void) {
        let snapshot = Progress(totalUnitCount: Self.totalBytes)
        let files = zip(Self.fileBytes, completedFileBytes).map { size, completed in
            let file = Progress(totalUnitCount: size, parent: snapshot, pendingUnitCount: size)
            file.completedUnitCount = completed
            return file
        }
        withExtendedLifetime(files) { progressHandler(snapshot) }
    }
}

/// A downloader that downloads nothing: it reports each step of `steps` as a
/// `Progress`, and then returns a folder or throws ``FakeLoadError``.
private struct StepDownloader: Downloader {
    /// The steps that the download reports, in order.
    private let steps: [SnapshotStep]

    /// Whether the download throws ``FakeLoadError`` after its reports.
    private let fails: Bool

    /// Makes a downloader.
    ///
    /// - Parameters:
    ///   - steps: The steps that the download reports, in order.
    ///   - fails: Whether the download throws ``FakeLoadError`` after its
    ///     reports.
    init(steps: [SnapshotStep], fails: Bool = false) {
        self.steps = steps
        self.fails = fails
    }

    /// Reports each step of ``steps``, and then returns the temporary folder
    /// or throws.
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
        for step in steps {
            step.report(to: progressHandler)
        }
        if fails {
            throw FakeLoadError()
        }
        return FileManager.default.temporaryDirectory
    }
}
