import Foundation
import HuggingFace
import MLXLMCommon
import Synchronization
import Testing

@testable import FoundationModelsExtras

/// The downloader of ``HubSource``, which the MLX, Core ML and GGUF loaders
/// all download with: a file request that stalls stops after the stall
/// interval, and the next attempt asks for the rest of the file with a
/// `Range` request. A download also continues the `.incomplete` blob of an
/// earlier download. Each test uses a temporary Hugging Face cache, a
/// ``HubStub`` whose file requests can stall, and a ``StallClock``, thus no
/// test uses the network or waits on the wall clock.
@Suite("Hub source downloader: a download continues from the bytes that it wrote", .timeLimit(.minutes(1)))
struct StalledDownloadTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The commit of the repository on the Hub.
    private static let commit = "fedcba9876543210fedcba9876543210fedcba98"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The bytes that the first request sends before it stalls.
    private static let bytesBeforeStall = 40

    /// The bytes that each request sends before it stalls, when each attempt
    /// stalls.
    private static let bytesOfEachStall = 10

    /// The retries after the first attempt.
    private static let retryLimit = 2

    /// The patterns of the files of the download.
    private static let patterns = ["*.safetensors"]

    /// The HTTP status of a request for a file that the repository does not
    /// hold.
    private static let missingStatus = 404

    @Test("the retry after a stall asks for the bytes after the bytes that the download wrote")
    func retrySendsRange() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights], stalls: [Self.bytesBeforeStall]))

        _ = try await download(stub: stub, fixture: fixture)

        #expect(stub.ranges == [nil, "bytes=\(Self.bytesBeforeStall)-"])
    }

    @Test("a download that stalls one time gives the bytes of the file")
    func retryGivesFile() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights], stalls: [Self.bytesBeforeStall]))

        let snapshot = try await download(stub: stub, fixture: fixture)

        #expect(try Data(contentsOf: snapshot.appendingPathComponent(Self.weights.path)) == Self.weights.contents)
    }

    @Test("a download whose each attempt stalls throws the stall error after the retry limit")
    func eachAttemptStallsThrows() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stalls = Array(repeating: Self.bytesOfEachStall, count: Self.retryLimit + 1)
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights], stalls: stalls))

        await #expect(
            throws: ModelDownloadError.stalled(
                repository: Self.repository, file: Self.weights.path, attempts: Self.retryLimit + 1)
        ) {
            try await download(stub: stub, fixture: fixture)
        }
    }

    @Test("the backoff before each retry is two times the backoff before the last retry")
    func backoffDoubles() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stalls = Array(repeating: Self.bytesOfEachStall, count: Self.retryLimit + 1)
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights], stalls: stalls))
        let clock = StallClock(stub: stub, retryLimit: Self.retryLimit)

        _ = try? await download(stub: stub, fixture: fixture, clock: clock)

        #expect(clock.backoffs == [StallClock.initialBackoff, StallClock.initialBackoff * 2])
    }

    @Test("the download progress never goes backward over a retry")
    func progressNeverGoesBackward() async throws {
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights], stalls: [Self.bytesBeforeStall]))
        let reports = ReportLog()
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let source = HubSource(
            cache: fixture.cache, tokenProvider: .none, session: stub.session,
            retryPolicy: StallClock(stub: stub, retryLimit: Self.retryLimit).policy)
        let downloader = ProgressReportingDownloader(upstream: source.downloader()) { reports.append($0) }

        _ = try await downloader.download(
            id: Self.repository, revision: Self.commit, matching: Self.patterns, useLatest: false
        ) { stub.recordWritten($0.completedUnitCount) }

        let completed = reports.completedBytes
        #expect(completed.contains(Int64(Self.bytesBeforeStall)) && completed == completed.sorted())
    }

    @Test("a download continues the .incomplete blob of an earlier download with a Range request")
    func earlierBlobSendsRange() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeIncomplete(Self.weights, bytes: Self.bytesBeforeStall)
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights]))

        _ = try await download(stub: stub, fixture: fixture)

        #expect(stub.ranges == ["bytes=\(Self.bytesBeforeStall)-"])
    }

    @Test("a download whose .incomplete blob holds each byte asks for the whole file after the server refuses the range")
    func fullBlobAsksAgain() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeIncomplete(Self.weights, bytes: Self.weights.size)
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights]))

        _ = try await download(stub: stub, fixture: fixture)

        #expect(stub.ranges == ["bytes=\(Self.weights.size)-", nil])
    }

    @Test("a download after the server refuses the range gives the bytes of the file")
    func fullBlobGivesFile() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeIncomplete(Self.weights, bytes: Self.weights.size)
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights]))

        let snapshot = try await download(stub: stub, fixture: fixture)

        #expect(try Data(contentsOf: snapshot.appendingPathComponent(Self.weights.path)) == Self.weights.contents)
    }

    @Test("a download of more files than download at the same time gives each file")
    func moreFilesThanConcurrentDownloads() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let shards = (0...BlobReusingDownloader.maximumConcurrentDownloads).map { index in
            HubStub.TreeFile(path: "model-\(index).safetensors", size: Self.bytesOfEachStall, isLFS: true)
        }
        let stub = HubStub(.repository(commit: Self.commit, files: shards))

        let snapshot = try await download(stub: stub, fixture: fixture)

        let contents = try shards.map { try Data(contentsOf: snapshot.appendingPathComponent($0.path)) }
        #expect(contents == shards.map(\.contents))
    }

    @Test("a file request that the server refuses throws the HTTP error of the answer")
    func refusedRequestThrowsHTTPError() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stub = HubStub(.repository(commit: Self.commit, files: []))
        let files = ResumableFileDownload(
            session: stub.session, host: HubSource.host(), tokenProvider: .none,
            policy: StallClock(stub: stub, retryLimit: Self.retryLimit).policy)
        let blob = try fixture.cache.incompleteBlobPath(repo: fixture.repo, kind: .model, etag: Self.weights.etag)
        try FileManager.default.createDirectory(
            at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)

        let error = await #expect(throws: HTTPClientError.self) {
            try await files.download(Self.weights.path, of: fixture.repo, at: Self.commit, into: blob) { _ in }
        }

        #expect(Self.statusCode(of: error) == Self.missingStatus)
    }

    /// The HTTP status of the answer of an HTTP error.
    ///
    /// - Parameter error: The error, or `nil`.
    /// - Returns: The status, or `nil` when the error is not an error of an
    ///   answer.
    private static func statusCode(of error: HTTPClientError?) -> Int? {
        guard case .responseError(let response, _) = error else { return nil }
        return response.statusCode
    }

    /// Downloads the files of the patterns at the commit with the downloader
    /// of a source over the cache of `fixture`, whose requests go to `stub`.
    /// The progress of the download goes to `stub`, thus a stall ends the
    /// watch of the clock only after the download wrote its bytes.
    ///
    /// - Parameters:
    ///   - stub: The transport.
    ///   - fixture: The cache.
    ///   - clock: The clock of the retry policy, or `nil` for a new clock
    ///     over `stub`.
    /// - Returns: The snapshot folder that the download gives.
    /// - Throws: The error of the download.
    private func download(stub: HubStub, fixture: HubFixture, clock: StallClock? = nil) async throws -> URL {
        let policy = (clock ?? StallClock(stub: stub, retryLimit: Self.retryLimit)).policy
        let source = HubSource(cache: fixture.cache, tokenProvider: .none, session: stub.session, retryPolicy: policy)
        return try await source.downloader().download(
            id: Self.repository, revision: Self.commit, matching: Self.patterns, useLatest: false
        ) { stub.recordWritten($0.completedUnitCount) }
    }
}

/// The ``ModelLoadProgress`` reports of a download, in order.
private final class ReportLog: Sendable {
    /// The reports.
    private let reports = Mutex<[ModelLoadProgress]>([])

    /// Records a report.
    ///
    /// - Parameter report: The report.
    func append(_ report: ModelLoadProgress) {
        reports.withLock { $0.append(report) }
    }

    /// The completed bytes of each download report, in order.
    var completedBytes: [Int64] {
        reports.withLock { reports in
            reports.compactMap { report in
                guard case .downloading(let completedBytes, _) = report else { return nil }
                return completedBytes
            }
        }
    }
}
