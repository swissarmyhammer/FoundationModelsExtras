import Foundation
import HuggingFace
import Testing

@testable import FoundationModelsExtras

/// The download of one file into its `.incomplete` blob: the token of a
/// request goes only to the host of the Hub, and a cancel of the caller stops
/// the transfer and keeps the bytes that it wrote. Each test uses a temporary
/// Hugging Face cache and a ``HubStub``, thus no test uses the network or
/// waits on the wall clock.
@Suite("Resumable file download: redirects and cancels", .timeLimit(.minutes(1)))
struct ResumableFileDownloadTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The commit of the repository on the Hub.
    private static let commit = "fedcba9876543210fedcba9876543210fedcba98"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The bytes of the `.incomplete` blob before the download, thus each
    /// request holds a `Range` header.
    private static let bytesBefore = 40

    /// The Hugging Face token of the requests.
    private static let token = "hf_test_token"

    /// The header of the token of a request.
    private static let authorizationField = "Authorization"

    /// The header of a request that asks for a part of a file.
    private static let rangeField = "Range"

    /// The base URL of a redirect to a host that is not the host of the Hub.
    private static let otherHost = URL(string: "https://cdn.hub-stub.test/files")

    /// The retries after the first attempt.
    private static let retryLimit = 2

    /// The bytes that the request sends before it stalls.
    private static let bytesBeforeStall = 30

    /// The number of a stall that never occurs: a watch that waits for it
    /// ends only with a cancel.
    private static let neverReachedStall = Int.max

    @Test("a redirect to another host sends no token to that host")
    func crossHostRedirectDropsToken() async throws {
        let redirect = try #require(Self.otherHost)
        let stub = try await downloadWithRedirect(to: redirect)

        #expect(stub.headerValues(Self.authorizationField, ofRequestsTo: redirect.host) == [nil])
    }

    @Test("a redirect to another host keeps the Range header")
    func crossHostRedirectKeepsRange() async throws {
        let redirect = try #require(Self.otherHost)
        let stub = try await downloadWithRedirect(to: redirect)

        #expect(stub.headerValues(Self.rangeField, ofRequestsTo: redirect.host) == ["bytes=\(Self.bytesBefore)-"])
    }

    @Test("a redirect to the host of the Hub keeps the token")
    func sameHostRedirectKeepsToken() async throws {
        let hub = HubSource.host()
        let stub = try await downloadWithRedirect(to: hub.appending(path: "redirected"))

        #expect(
            stub.headerValues(Self.authorizationField, ofRequestsTo: hub.host)
                == ["Bearer \(Self.token)", "Bearer \(Self.token)"])
    }

    @Test("a cancel of the caller task gives CancellationError to the caller")
    func cancelThrowsCancellationError() async throws {
        let cancelled = try await cancelledDownload()

        #expect(throws: CancellationError.self) { try cancelled.result.get() }
    }

    @Test("a cancel of the caller task keeps the bytes of the .incomplete blob")
    func cancelKeepsBytes() async throws {
        let cancelled = try await cancelledDownload()

        #expect(cancelled.blobBytes == Self.bytesBefore + Self.bytesBeforeStall)
    }

    @Test("a cancel of the caller task stops the transfer, and the download sends no new request")
    func cancelSendsNoRetry() async throws {
        let cancelled = try await cancelledDownload()

        #expect(cancelled.ranges == ["bytes=\(Self.bytesBefore)-"])
    }

    /// Starts a download of the weights whose request stalls, and cancels
    /// the task of the download when the download wrote each byte that the
    /// request sent. The `.incomplete` blob holds ``bytesBefore`` bytes
    /// before the download. The watch of the transfer waits until the
    /// cancel, thus only the cancel stops the transfer.
    ///
    /// - Returns: The outcome of the download, the bytes of the blob after
    ///   the download, and the `Range` header of each file request.
    /// - Throws: The error of the fixture, or `CancellationError` when the
    ///   test is cancelled.
    private func cancelledDownload() async throws -> CancelledDownload {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeIncomplete(Self.weights, bytes: Self.bytesBefore)
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights], stalls: [Self.bytesBeforeStall]))
        let policy = DownloadRetryPolicy(retryLimit: Self.retryLimit) { _ in
            try await stub.waitForStall(number: Self.neverReachedStall)
        }
        let files = ResumableFileDownload(
            session: stub.session, host: HubSource.host(), tokenProvider: .none, policy: policy)
        let blob = try fixture.cache.incompleteBlobPath(repo: fixture.repo, kind: .model, etag: Self.weights.etag)
        let download = Task {
            try await files.download(Self.weights.path, of: fixture.repo, at: Self.commit, into: blob) {
                stub.recordWritten($0)
            }
        }

        try await stub.waitForStall(number: 1)
        download.cancel()
        let result = await download.result
        let blobBytes = try FileManager.default.attributesOfItem(atPath: blob.path)[.size] as? Int
        return CancelledDownload(result: result, blobBytes: blobBytes, ranges: stub.ranges)
    }

    /// Downloads the weights with a token, from a stub that redirects each
    /// file request to the same path under `redirect`. The `.incomplete`
    /// blob holds ``bytesBefore`` bytes before the download.
    ///
    /// - Parameter redirect: The base URL of the redirect.
    /// - Returns: The stub, which recorded each request.
    /// - Throws: The error of the download.
    private func downloadWithRedirect(to redirect: URL) async throws -> HubStub {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        try fixture.writeIncomplete(Self.weights, bytes: Self.bytesBefore)
        let stub = HubStub(.repository(commit: Self.commit, files: [Self.weights], redirect: redirect))
        let files = ResumableFileDownload(
            session: stub.session, host: HubSource.host(), tokenProvider: .fixed(token: Self.token),
            policy: StallClock(stub: stub, retryLimit: Self.retryLimit).policy)
        let blob = try fixture.cache.incompleteBlobPath(repo: fixture.repo, kind: .model, etag: Self.weights.etag)

        try await files.download(Self.weights.path, of: fixture.repo, at: Self.commit, into: blob) {
            stub.recordWritten($0)
        }
        return stub
    }
}

/// The outcome of a download whose task was cancelled.
private struct CancelledDownload {
    /// The outcome of the download.
    let result: Result<Void, any Error>

    /// The bytes of the `.incomplete` blob after the download, or `nil` when
    /// the blob does not exist.
    let blobBytes: Int?

    /// The `Range` header of each file request, in order.
    let ranges: [String?]
}
