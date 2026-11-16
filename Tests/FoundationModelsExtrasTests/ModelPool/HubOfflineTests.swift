import FixtureSupport
import Foundation
import HuggingFace
import Testing

@testable import FoundationModelsExtras

/// The offline mode of ``HubSource``: no request goes to the Hub, and each
/// model comes from the cache. Each stub of these tests answers as the Hub
/// does, thus an online call would get a different result. Each test that
/// uses a stub also proves that the stub got no request.
@Suite("Hub offline mode: no request to the Hub, only the cache")
struct HubOfflineTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The repository of the GGUF tests.
    private static let ggufRepository = "org/model-GGUF"

    /// The commit of the files in the cache.
    private static let cachedCommit = "0123456789abcdef0123456789abcdef01234567"

    /// The commit of the repository on the Hub.
    private static let hubCommit = "fedcba9876543210fedcba9876543210fedcba98"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The configuration of the model, a file that is not LFS.
    private static let config = HubStub.TreeFile(path: "config.json", size: 10, isLFS: false)

    /// The GGUF model file.
    private static let ggufModel = HubStub.TreeFile(path: "Q4_K_M/model-Q4_K_M.gguf", size: 40, isLFS: true)

    /// The patterns of the files of the download.
    private static let patterns = ["*.safetensors", "*.json"]

    // MARK: - HF_HUB_OFFLINE

    @Test(
        "HF_HUB_OFFLINE turns the mode on for each value of on, with no case",
        arguments: ["1", "true", "yes", "on", "TRUE", "Yes", "ON", " 1 "])
    func environmentValueOn(value: String) {
        #expect(HubSource.isOffline(given: nil, environment: [HubSource.offlineVariable: value]))
    }

    @Test(
        "HF_HUB_OFFLINE keeps the mode off for each other value",
        arguments: ["0", "false", "no", "off", "", "2", "offline"])
    func environmentValueOff(value: String) {
        #expect(!HubSource.isOffline(given: nil, environment: [HubSource.offlineVariable: value]))
    }

    @Test("with no HF_HUB_OFFLINE the mode is off")
    func noEnvironmentValue() {
        #expect(!HubSource.isOffline(given: nil, environment: [:]))
    }

    @Test("a given value wins over HF_HUB_OFFLINE", arguments: [true, false])
    func givenValueWins(given: Bool) {
        let environment = [HubSource.offlineVariable: given ? "0" : "1"]

        #expect(HubSource.isOffline(given: given, environment: environment) == given)
    }

    // MARK: - The downloader

    @Test("an offline download of a cached snapshot gives the snapshot of the ref file")
    func offlineDownloadGivesCachedSnapshot() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.repository(commit: Self.hubCommit, files: [Self.weights, Self.config]))

        let snapshot = try await offlineDownload(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)

        #expect(snapshot.lastPathComponent == Self.cachedCommit)
    }

    @Test("an offline download of a cached snapshot sends no request")
    func offlineDownloadSendsNoRequest() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.repository(commit: Self.hubCommit, files: [Self.weights, Self.config]))

        _ = try await offlineDownload(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)

        #expect(stub.requests.isEmpty)
    }

    @Test("an offline download of a model that is not cached throws notCachedOffline")
    func offlineDownloadOfMissingModelThrows() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        let stub = HubStub(.repository(commit: Self.hubCommit, files: [Self.weights, Self.config]))

        await #expect(
            throws: ModelDownloadError.notCachedOffline(
                repository: Self.repository, revision: ModelRef.defaultRevision)
        ) {
            try await offlineDownload(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)
        }
    }

    @Test("an offline download of a model that is not cached sends no request")
    func offlineDownloadOfMissingModelSendsNoRequest() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        let stub = HubStub(.repository(commit: Self.hubCommit, files: [Self.weights, Self.config]))

        _ = try? await offlineDownload(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)

        #expect(stub.requests.isEmpty)
    }

    // MARK: - GGUF

    @Test("an offline GGUF source gives the files of a cached snapshot")
    func offlineGGUFGivesCachedFiles() async throws {
        let fixture = try HubFixture(repository: Self.ggufRepository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.ggufModel])
        let stub = HubStub(.repository(commit: Self.hubCommit, files: [Self.ggufModel]))

        let files = try await offlineGGUFSource(fixture: fixture, stub: stub)
            .files(of: ModelRef("\(Self.ggufRepository)/Q4_K_M")) { _ in }

        #expect(files.model.lastPathComponent == "model-Q4_K_M.gguf")
    }

    @Test("an offline GGUF source sends no request for a cached snapshot")
    func offlineGGUFSendsNoRequest() async throws {
        let fixture = try HubFixture(repository: Self.ggufRepository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.ggufModel])
        let stub = HubStub(.repository(commit: Self.hubCommit, files: [Self.ggufModel]))

        _ = try await offlineGGUFSource(fixture: fixture, stub: stub)
            .files(of: ModelRef("\(Self.ggufRepository)/Q4_K_M")) { _ in }

        #expect(stub.requests.isEmpty)
    }

    @Test("an offline GGUF source throws notCachedOffline for a model that is not cached, with no request")
    func offlineGGUFOfMissingModelThrows() async throws {
        let fixture = try HubFixture(repository: Self.ggufRepository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        let stub = HubStub(.repository(commit: Self.hubCommit, files: [Self.ggufModel]))

        await #expect(
            throws: ModelDownloadError.notCachedOffline(
                repository: Self.ggufRepository, revision: ModelRef.defaultRevision)
        ) {
            try await offlineGGUFSource(fixture: fixture, stub: stub)
                .files(of: ModelRef("\(Self.ggufRepository)/Q4_K_M")) { _ in }
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - Storage

    @Test("an offline storage sends no request for the tree listing")
    func offlineStorageSendsNoRequest() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.tree([Self.weights, Self.config]))

        _ = try await fixture.storage(stub, offline: true).storageInfo(of: ModelRef(Self.repository))

        #expect(stub.requests.isEmpty)
    }

    @Test("an offline storage with no kept listing has no total, and the state of the snapshot")
    func offlineStorageUsesSnapshot() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.tree([Self.weights, Self.config]))

        let info = try await fixture.storage(stub, offline: true).storageInfo(of: ModelRef(Self.repository))

        #expect(info.totalBytes == nil && info.state == .complete)
    }

    // MARK: - The public inits

    @Test("an offline Hub loader throws notCachedOffline for a model that is not cached")
    func offlineHubLoaderOfMissingModelThrows() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = HubModelLoader(cacheDirectory: root, offline: true)

        await #expect(
            throws: ModelDownloadError.notCachedOffline(repository: Self.repository, revision: ModelRef.defaultRevision)
        ) {
            try await loader.load(ModelPoolKey(ref: ModelRef(Self.repository), role: .llm))
        }
    }

    @Test("an offline MLX loader throws notCachedOffline for a model that is not cached")
    func offlineMLXLoaderOfMissingModelThrows() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = MLXModelLoader(cacheDirectory: root, offline: true)

        await #expect(
            throws: ModelDownloadError.notCachedOffline(repository: Self.repository, revision: ModelRef.defaultRevision)
        ) {
            try await loader.load(ModelPoolKey(ref: ModelRef(Self.repository), role: .embedding))
        }
    }

    @Test("an offline Core ML loader throws notCachedOffline for a model that is not cached")
    func offlineCoreMLLoaderOfMissingModelThrows() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = CoreMLModelLoader(cacheDirectory: root, offline: true)

        await #expect(
            throws: ModelDownloadError.notCachedOffline(repository: Self.repository, revision: ModelRef.defaultRevision)
        ) {
            try await loader.load(ModelPoolKey(ref: ModelRef(Self.repository), role: .embedding))
        }
    }

    @Test("an offline GGUF source of the public init throws notCachedOffline for a model that is not cached")
    func offlinePublicGGUFSourceOfMissingModelThrows() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = GGUFSource(cacheDirectory: root, offline: true)

        await #expect(
            throws: ModelDownloadError.notCachedOffline(
                repository: Self.ggufRepository, revision: ModelRef.defaultRevision)
        ) {
            try await source.files(of: ModelRef("\(Self.ggufRepository)/Q4_K_M")) { _ in }
        }
    }

    @Test("an offline storage of the public init gives the snapshot state with no total")
    func offlinePublicStorageUsesSnapshot() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.cachedCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])

        let info = try await ModelStorage(cacheDirectory: fixture.root, offline: true)
            .storageInfo(of: ModelRef(Self.repository))

        #expect(info.totalBytes == nil && info.state == .complete)
    }

    // MARK: - Helpers

    /// Downloads the files of the patterns at `revision` with the downloader
    /// of an offline source over the cache of `fixture`, whose requests go to
    /// `stub`.
    ///
    /// - Parameters:
    ///   - revision: The revision to download.
    ///   - fixture: The cache.
    ///   - stub: The transport.
    /// - Returns: The snapshot folder that the download gives.
    /// - Throws: The error of the download.
    private func offlineDownload(revision: String, fixture: HubFixture, stub: HubStub) async throws -> URL {
        let source = HubSource(cache: fixture.cache, tokenProvider: .none, session: stub.session, offline: true)
        return try await source.downloader().download(
            id: fixture.repo.rawValue, revision: revision, matching: Self.patterns, useLatest: false
        ) { _ in }
    }

    /// An offline GGUF source over the cache of `fixture`, whose requests go
    /// to `stub`.
    ///
    /// - Parameters:
    ///   - fixture: The cache.
    ///   - stub: The transport.
    /// - Returns: The source.
    private func offlineGGUFSource(fixture: HubFixture, stub: HubStub) -> GGUFSource {
        GGUFSource(hub: HubSource(cache: fixture.cache, tokenProvider: .none, session: stub.session, offline: true))
    }
}
