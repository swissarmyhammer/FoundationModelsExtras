import FixtureSupport
import Foundation
@testable import FoundationModelsExtras
import HuggingFace
import InMemoryTracing
import MLXLMCommon
import TelemetryTestSupport
import Testing
import Tracing

/// The built-in MLX loader keeps the tokenizer loader that its init gets,
/// measures the weight files of a model in the Hugging Face cache, makes the
/// MLX metal library available to the test binary, and reports the progress
/// of its download.
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

    /// The repository of the MTP drafter of a key that names one.
    private static let drafter = "org/model-mtp"

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

    /// The mark of the tokenizer loader that a test gives to a loader.
    private static let tokenizerLoaderMark = "pinned-date chat template"

    /// The bytes of a download whose cache holds the files.
    private static let noDownloadedBytes: Int64 = 0

    /// The number of download spans that one download opens.
    private static let oneDownloadSpan = 1

    @Test("a loader keeps the tokenizer loader that its init gets")
    func loaderKeepsTheGivenTokenizerLoader() throws {
        let loader = MLXModelLoader(tokenizerLoader: MarkedTokenizerLoader(mark: Self.tokenizerLoaderMark))

        let kept = try #require(loader.tokenizerLoader as? MarkedTokenizerLoader)

        #expect(kept.mark == Self.tokenizerLoaderMark)
    }

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

    @Test("the footprint of a key whose ref names an MTP drafter adds the weight files of the drafter")
    func footprintAddsTheDrafter() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(in: cache, ref: MLXModelLoader.defaultRevision, commit: Self.mainCommit)
        try Self.writeSnapshot(
            in: cache, ref: MLXModelLoader.defaultRevision, commit: Self.pinnedCommit, repository: Self.drafter)
        let loader = MLXModelLoader(cache: cache)
        let ref = ModelRef(repo: Self.repository, drafter: ModelRef(Self.drafter))

        let bytes = try await loader.footprintBytes(of: ModelPoolKey(ref: ref, role: .llm))

        #expect(bytes == 2 * Int64(Self.firstWeightBytes + Self.secondWeightBytes))
    }

    @Test("an LLM key with no drafter speculates with nothing")
    func noDrafterNoSpeculation() throws {
        let loader = MLXModelLoader(cache: HubCache(cacheDirectory: URL(fileURLWithPath: "/nonexistent")))

        #expect(try loader.speculativeDecoding(for: ModelPoolKey(ref: ModelRef(Self.repository), role: .llm)) == nil)
    }

    @Test("an LLM key whose ref names a drafter speculates with that drafter at its revision")
    func drafterSpeculates() throws {
        let loader = MLXModelLoader(cache: HubCache(cacheDirectory: URL(fileURLWithPath: "/nonexistent")))
        let ref = ModelRef(repo: Self.repository, drafter: ModelRef(repo: Self.drafter, revision: Self.pinnedCommit))

        let speculation = try #require(try loader.speculativeDecoding(for: ModelPoolKey(ref: ref, role: .llm)))

        guard case .id(let id, let revision) = speculation.drafterConfiguration.id else {
            Issue.record("the drafter configuration is not a model id")
            return
        }
        #expect(id == Self.drafter)
        #expect(revision == Self.pinnedCommit)
    }

    @Test("an MTP drafter loads under the recommended working set, which falls back to plain decode when it does not fit")
    func drafterHasAMemoryPolicy() throws {
        let loader = MLXModelLoader(cache: HubCache(cacheDirectory: URL(fileURLWithPath: "/nonexistent")))
        let ref = ModelRef(repo: Self.repository, drafter: ModelRef(Self.drafter))

        let speculation = try #require(try loader.speculativeDecoding(for: ModelPoolKey(ref: ref, role: .llm)))

        #expect(speculation.memoryPolicy == .recommendedWorkingSet)
        #expect(speculation.memoryPolicy?.action == .fallbackToDefault)
    }

    @Test("a cached MTP drafter states its weight bytes, so the memory policy weighs it before it loads")
    func cachedDrafterStatesItsBytes() throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        try Self.writeSnapshot(
            in: cache, ref: MLXModelLoader.defaultRevision, commit: Self.mainCommit, repository: Self.drafter)
        let loader = MLXModelLoader(cache: cache)
        let ref = ModelRef(repo: Self.repository, drafter: ModelRef(Self.drafter))

        let speculation = try #require(try loader.speculativeDecoding(for: ModelPoolKey(ref: ref, role: .llm)))

        #expect(speculation.drafterBytes == Self.firstWeightBytes + Self.secondWeightBytes)
    }

    @Test("a drafter that the cache does not hold yet states no bytes, so the policy weighs it after it loads")
    func uncachedDrafterStatesNoBytes() throws {
        let loader = MLXModelLoader(cache: HubCache(cacheDirectory: URL(fileURLWithPath: "/nonexistent")))
        let ref = ModelRef(repo: Self.repository, drafter: ModelRef(Self.drafter))

        let speculation = try #require(try loader.speculativeDecoding(for: ModelPoolKey(ref: ref, role: .llm)))

        #expect(speculation.drafterBytes == nil)
    }

    @Test("a drafter with no revision speculates with the main revision of the drafter")
    func drafterDefaultRevision() throws {
        let loader = MLXModelLoader(cache: HubCache(cacheDirectory: URL(fileURLWithPath: "/nonexistent")))
        let ref = ModelRef(repo: Self.repository, drafter: ModelRef(Self.drafter))

        let speculation = try #require(try loader.speculativeDecoding(for: ModelPoolKey(ref: ref, role: .llm)))

        guard case .id(_, let revision) = speculation.drafterConfiguration.id else {
            Issue.record("the drafter configuration is not a model id")
            return
        }
        #expect(revision == MLXModelLoader.defaultRevision)
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

    @Test("a loader with a cache folder downloads to that folder, also when HF_HUB_CACHE and HF_HOME name another")
    func cacheFolderIsTheDownloadFolder() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: other) }
        let defaultFolder = HubCache.default.cacheDirectory

        let loader = await Self.withEnvironment(
            ["HF_HUB_CACHE": other.path, "HF_HOME": other.path]
        ) { MLXModelLoader(cacheDirectory: root) }

        let downloadFolder = try #require(loader.hubClient().cache?.cacheDirectory)
        #expect(downloadFolder == root)
        #expect(HubCache.default.cacheDirectory == defaultFolder)
        #expect(
            MLXModelLoader.weightsDirectory(of: Self.repository, in: HubCache(cacheDirectory: root)).path
                .hasPrefix(root.path))
    }

    @Test("a loader with no cache folder downloads to the default Hugging Face cache")
    func noCacheFolderUsesTheDefaultCache() throws {
        let loader = MLXModelLoader()

        let downloadFolder = try #require(loader.hubClient().cache?.cacheDirectory)

        #expect(downloadFolder == HubCache.default.cacheDirectory)
    }

    @Test("the footprint of a loader with a cache folder measures the weights in that folder")
    func footprintReadsTheGivenCacheFolder() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(
            in: HubCache(cacheDirectory: root), ref: MLXModelLoader.defaultRevision, commit: Self.mainCommit)
        let loader = MLXModelLoader(cacheDirectory: root)

        let bytes = try await loader.footprintBytes(of: ModelPoolKey(ref: ModelRef(Self.repository), role: .llm))

        #expect(bytes == Int64(Self.firstWeightBytes + Self.secondWeightBytes))
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

    @Test("a download opens one download span with the completed bytes of its last report")
    func aDownloadOpensOneSpanWithItsBytes() async throws {
        let span = try await Self.downloadSpan(of: StepDownloader(steps: [.noBytes, .partOfFirstFile]))

        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.downloadBytes) == .int64(SnapshotStep.totalBytes))
        #expect(span.status == nil)
    }

    @Test("a download whose cache holds the files opens one download span with no downloaded bytes")
    func aCachedDownloadSpanHasNoBytes() async throws {
        let span = try await Self.downloadSpan(of: StepDownloader(steps: [.allBytes]))

        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.downloadBytes) == .int64(Self.noDownloadedBytes))
    }

    @Test("a failed download span has the error status and the completed bytes of its last report")
    func aFailedDownloadSpanHasItsBytes() async throws {
        let span = try await Self.downloadSpan(of: StepDownloader(steps: [.noBytes, .partOfFirstFile], fails: true))

        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.downloadBytes)
                == .int64(SnapshotStep.partOfFirstFile.completedBytes))
        #expect(span.status?.code == .error)
    }

    /// Downloads with a ``ProgressReportingDownloader`` over `upstream`
    /// under a ``W3CInMemoryTracer``, and gives the one download span.
    ///
    /// - Parameter upstream: The fake downloader. Its error does not end the
    ///   test: the span records it.
    /// - Returns: The one download span of the download.
    /// - Throws: When the tracer holds no download span, or more than one.
    private static func downloadSpan(of upstream: StepDownloader) async throws -> FinishedInMemorySpan {
        let tracer = W3CInMemoryTracer()
        let downloader = ProgressReportingDownloader(upstream: upstream) { _ in }
        _ = try? await withTracer(tracer) {
            try await downloader.download(
                id: repository, revision: MLXModelLoader.defaultRevision, matching: [], useLatest: false) { _ in }
        }
        let spans = ModelLoadTelemetryExpectations.spans(
            named: ExtrasTelemetry.SpanName.modelLoadDownload, in: tracer.finishedSpans)
        #expect(spans.count == oneDownloadSpan)
        return try #require(spans.first)
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

    /// Runs `body` while the process environment holds `variables`, and then
    /// puts back the old values.
    ///
    /// - Parameters:
    ///   - variables: The names and values to set. A `nil` value removes the
    ///     variable.
    ///   - body: The work to run.
    /// - Returns: The result of `body`.
    /// - Throws: The error of `body`.
    private static func withEnvironment<Result>(
        _ variables: [String: String?], _ body: () async throws -> Result
    ) async rethrows -> Result {
        let old = variables.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (name, value) in variables {
            setEnvironmentVariable(name, to: value)
        }
        defer {
            for (name, value) in old {
                setEnvironmentVariable(name, to: value)
            }
        }
        return try await body()
    }

    /// Sets the process environment variable `name` to `value`.
    ///
    /// - Parameters:
    ///   - name: The name of the variable.
    ///   - value: The value, or `nil` to remove the variable.
    private static func setEnvironmentVariable(_ name: String, to value: String?) {
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
    }

    /// Writes one snapshot of `repository` in `cache`: two weight files and
    /// one configuration file, each a link to a blob.
    ///
    /// - Parameters:
    ///   - cache: The cache to write in.
    ///   - ref: The ref file to write, which names `commit`, or `nil` for no
    ///     ref file.
    ///   - commit: The commit of the snapshot.
    ///   - repository: The repository of the snapshot, ``repository`` when
    ///     not given.
    /// - Throws: The error of a file write.
    private static func writeSnapshot(
        in cache: HubCache, ref: String?, commit: String, repository: String = repository
    ) throws {
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

extension MLXModelLoaderTests {
    /// The hub client of each download sends the token of the token provider
    /// of the loader, and goes to the host of `HF_ENDPOINT`.
    ///
    /// Each test reads its token with `bearerToken`, so no test makes a
    /// request. The tests that set `HF_TOKEN` or `HF_ENDPOINT` change the
    /// environment of the process, thus the suite runs them one at a time.
    @Suite("MLX model loader: the token and the host of the hub client", .serialized)
    struct HubClientTests {
        /// The token of the fixed token provider that a test gives to a loader.
        private static let fixedToken = "t"

        /// The token that a test puts in `HF_TOKEN`.
        private static let environmentToken = "hf_environment_token"

        /// The host name of the endpoint that a test puts in `HF_ENDPOINT`.
        private static let endpointHost = "hub.example.test"

        /// The Hugging Face endpoint that a test puts in `HF_ENDPOINT`.
        private static let endpoint = "https://\(endpointHost)"

        @Test("a loader with a fixed token provider gives a hub client that sends that token")
        func fixedTokenProviderGivesItsToken() async {
            let loader = MLXModelLoader(tokenProvider: .fixed(token: Self.fixedToken))

            #expect(await loader.hubClient().bearerToken == Self.fixedToken)
        }

        @Test("a loader with no token provider gives a hub client that sends no token, also when HF_TOKEN holds one")
        func noTokenProviderGivesNoToken() async {
            let token = await MLXModelLoaderTests.withEnvironment(["HF_TOKEN": Self.environmentToken]) {
                await MLXModelLoader(tokenProvider: .none).hubClient().bearerToken
            }

            #expect(token == nil)
        }

        @Test("a loader with the default token provider gives a hub client that sends the token of HF_TOKEN")
        func defaultTokenProviderReadsTheEnvironment() async {
            let token = await MLXModelLoaderTests.withEnvironment(["HF_TOKEN": Self.environmentToken]) {
                await MLXModelLoader().hubClient().bearerToken
            }

            #expect(token == Self.environmentToken)
        }

        @Test("a loader with a token provider gives a hub client whose host is the endpoint of HF_ENDPOINT")
        func hubClientHostIsTheEndpointOfTheEnvironment() async {
            let host = await MLXModelLoaderTests.withEnvironment(["HF_ENDPOINT": Self.endpoint]) {
                MLXModelLoader(tokenProvider: .none).hubClient().host
            }

            #expect(host.host() == Self.endpointHost)
        }

        @Test("a loader gives a hub client whose host is the Hugging Face Hub when HF_ENDPOINT is not set")
        func hubClientHostIsTheHubWithNoEndpoint() async {
            let host = await MLXModelLoaderTests.withEnvironment(["HF_ENDPOINT": nil]) {
                MLXModelLoader().hubClient().host
            }

            #expect(host.host() == HubClient.defaultHost.host())
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

/// A tokenizer loader that a test can know by its mark. It loads no tokenizer:
/// each load throws ``FakeLoadError``.
private struct MarkedTokenizerLoader: TokenizerLoader {
    /// The text that tells this tokenizer loader from a different one.
    let mark: String

    /// Throws, because the test runs no load.
    ///
    /// - Parameter directory: The folder of the tokenizer. The fake does not
    ///   read it.
    /// - Returns: No tokenizer.
    /// - Throws: ``FakeLoadError`` always.
    func load(from directory: URL) async throws -> any Tokenizer {
        throw FakeLoadError()
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
