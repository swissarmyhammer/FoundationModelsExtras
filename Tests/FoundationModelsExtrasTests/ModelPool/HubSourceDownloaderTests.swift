import Foundation
import HuggingFace
import TelemetryTestSupport
import Testing

@testable import FoundationModelsExtras

/// The downloader of ``HubSource``, which the MLX, Core ML and GGUF loaders
/// all download with: after the revision of a repository changes, a file whose
/// blob the cache already holds is not downloaded again. Each test uses a
/// temporary Hugging Face cache that holds the files of an old commit, and a
/// ``HubStub`` of the repository at a new commit. No test uses the network.
@Suite("Hub source downloader: a new revision reuses the cached blobs with the same hash")
struct HubSourceDownloaderTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The commit of the files in the cache.
    private static let oldCommit = "0123456789abcdef0123456789abcdef01234567"

    /// The commit of the repository on the Hub.
    private static let newCommit = "fedcba9876543210fedcba9876543210fedcba98"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The configuration of the model, a file that is not LFS.
    private static let config = HubStub.TreeFile(path: "config.json", size: 10, isLFS: false)

    /// The patterns of the files of the download.
    private static let patterns = ["*.safetensors", "*.json"]

    @Test("the download of a new commit makes no file request when the cache holds each blob")
    func noFileRequest() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.repository(commit: Self.newCommit, files: [Self.weights, Self.config]))

        _ = try await download(revision: Self.newCommit, fixture: fixture, stub: stub)

        #expect(stub.requests.filter { $0.pathComponents.contains(HubStub.resolveComponent) } == [])
    }

    @Test("the snapshot of the new commit links to the blob of the old commit")
    func linksOldBlob() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.repository(commit: Self.newCommit, files: [Self.weights, Self.config]))

        let snapshot = try await download(revision: Self.newCommit, fixture: fixture, stub: stub)

        let blob = try fixture.cache.blobPath(repo: fixture.repo, kind: .model, etag: Self.weights.etag)
        #expect(
            snapshot.appendingPathComponent(Self.weights.path).resolvingSymlinksInPath()
                == blob.resolvingSymlinksInPath())
    }

    @Test("the download of main after main moved gives the snapshot of the new commit")
    func movedRefGivesNewSnapshot() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.repository(commit: Self.newCommit, files: [Self.weights, Self.config]))

        let snapshot = try await download(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)

        #expect(snapshot.lastPathComponent == Self.newCommit)
    }

    @Test("the download of main after main moved writes the new commit in the ref")
    func movedRefIsWritten() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let stub = HubStub(.repository(commit: Self.newCommit, files: [Self.weights, Self.config]))

        _ = try await download(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)

        #expect(
            fixture.cache.resolveRevision(repo: fixture.repo, kind: .model, ref: ModelRef.defaultRevision)
                == Self.newCommit)
    }

    @Test("the snapshot of the new commit holds the reused file beside a file with a new hash")
    func reusedFileBesideNewFile() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights])
        let stub = HubStub(.repository(commit: Self.newCommit, files: [Self.weights, Self.config]))

        let snapshot = try await download(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)

        #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent(Self.weights.path).path))
    }

    @Test("a file with a new hash still downloads")
    func newHashDownloads() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights])
        let stub = HubStub(.repository(commit: Self.newCommit, files: [Self.weights, Self.config]))

        let snapshot = try await download(revision: ModelRef.defaultRevision, fixture: fixture, stub: stub)

        #expect(try Data(contentsOf: snapshot.appendingPathComponent(Self.config.path)) == Self.config.contents)
    }

    @Test("with no network the download gives the cached snapshot of the revision")
    func offlineGivesCachedSnapshot() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])

        let snapshot = try await download(revision: ModelRef.defaultRevision, fixture: fixture, stub: HubStub(.offline))

        #expect(snapshot.lastPathComponent == Self.oldCommit)
    }

    @Test("with no network the download writes one debug record with the error type and the repository")
    func offlineWritesDebugRecord() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.oldCommit)
        defer { fixture.remove() }
        try fixture.writeComplete([Self.weights, Self.config])
        let offlineError = try await requestError(of: fixture)

        let records = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await download(revision: ModelRef.defaultRevision, fixture: fixture, stub: HubStub(.offline))
            return context.logRecords.filter { $0.label == ExtrasTelemetry.logLabel }
        }

        let expected = TelemetryCapture.LogRecord(
            level: .debug,
            message: "\(ExtrasTelemetry.PoolLogMessage.revisionTreeUnavailable)",
            metadata: [
                ExtrasTelemetry.LogMetadataKey.errorType: .string(ExtrasTelemetry.errorType(of: offlineError)),
                ExtrasTelemetry.LogMetadataKey.repository: .string(Self.repository),
            ],
            label: ExtrasTelemetry.logLabel
        )
        #expect(records == [expected])
    }

    /// The error that a Hub request of a client with no network throws, as
    /// the session gives it to the client.
    ///
    /// - Parameter fixture: The cache of the client.
    /// - Returns: The error of the model information request.
    /// - Throws: An issue when the request does not fail.
    private func requestError(of fixture: HubFixture) async throws -> any Error {
        let client = HubSource(cache: fixture.cache, tokenProvider: .none, session: HubStub(.offline).session).client()
        return try #require(
            await #expect(throws: (any Error).self) {
                try await client.getModel(fixture.repo, revision: ModelRef.defaultRevision)
            })
    }

    /// Downloads the files of the patterns at `revision` with the downloader
    /// of a source over the cache of `fixture`, whose requests go to `stub`.
    ///
    /// - Parameters:
    ///   - revision: The revision to download.
    ///   - fixture: The cache.
    ///   - stub: The transport.
    /// - Returns: The snapshot folder that the download gives.
    /// - Throws: The error of the download.
    private func download(revision: String, fixture: HubFixture, stub: HubStub) async throws -> URL {
        let source = HubSource(cache: fixture.cache, tokenProvider: .none, session: stub.session)
        return try await source.downloader().download(
            id: Self.repository, revision: revision, matching: Self.patterns, useLatest: false
        ) { _ in }
    }
}
