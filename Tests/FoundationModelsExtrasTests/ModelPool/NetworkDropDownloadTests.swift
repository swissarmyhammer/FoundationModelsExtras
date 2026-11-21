import Foundation
import Testing

@testable import FoundationModelsExtras

/// The downloader of ``HubSource``: a file request that fails with a
/// transient network error, for example a lost connection, gets a new
/// request after the backoff, which asks for the bytes after the bytes that
/// the download wrote. Each test uses a temporary Hugging Face cache, a
/// ``HubStub`` whose file requests can drop, and a ``StallClock``, thus no
/// test uses the network or waits on the wall clock.
@Suite("Hub source downloader: a download survives a dropped connection", .timeLimit(.minutes(1)))
struct NetworkDropDownloadTests {
    /// The repository of the tests.
    private static let repository = "org/model"

    /// The commit of the repository on the Hub.
    private static let commit = "fedcba9876543210fedcba9876543210fedcba98"

    /// The weights of the model, an LFS file.
    private static let weights = HubStub.TreeFile(path: "model.safetensors", size: 100, isLFS: true)

    /// The bytes that the first request sends before the connection drops.
    private static let bytesBeforeDrop = 40

    /// The bytes that each request sends before the connection drops, when
    /// each request drops.
    private static let bytesOfEachDrop = 10

    /// The retries after a stall. No test of this suite stalls.
    private static let retryLimit = 2

    /// The retries after a network error, since the last attempt that wrote
    /// new bytes.
    private static let networkRetryLimit = 2

    /// The patterns of the files of the download.
    private static let patterns = ["*.safetensors"]

    /// The codes of the network errors that the download tries again.
    private static let transientCodes: [URLError.Code] = [
        .networkConnectionLost, .timedOut, .notConnectedToInternet, .dataNotAllowed, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed,
    ]

    @Test(
        "a dropped connection gets a retry that asks for the bytes after the written bytes", arguments: transientCodes)
    func dropOnceRetriesWithRange(code: URLError.Code) async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stub = HubStub(
            .repository(commit: Self.commit, files: [Self.weights], stalls: [Self.bytesBeforeDrop], dropsWith: code))

        let snapshot = try await download(stub: stub, fixture: fixture)

        #expect(stub.ranges == [nil, "bytes=\(Self.bytesBeforeDrop)-"])
        #expect(try Data(contentsOf: snapshot.appendingPathComponent(Self.weights.path)) == Self.weights.contents)
    }

    @Test("a connection that drops with no new bytes after the network retry limit throws the network error")
    func eachDropWithNoBytesThrows() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let drops = Array(repeating: 0, count: Self.networkRetryLimit + 1)
        let stub = HubStub(
            .repository(commit: Self.commit, files: [Self.weights], stalls: drops, dropsWith: .networkConnectionLost))

        let error = await #expect(throws: URLError.self) {
            try await download(stub: stub, fixture: fixture)
        }
        #expect(error?.code == .networkConnectionLost)
        #expect(stub.ranges.count == Self.networkRetryLimit + 1)
    }

    @Test("an attempt that wrote new bytes before the drop sets the count of the network retries to zero")
    func progressResetsTheRetryCount() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let dropCount = Self.networkRetryLimit * 2
        let drops = Array(repeating: Self.bytesOfEachDrop, count: dropCount)
        let stub = HubStub(
            .repository(commit: Self.commit, files: [Self.weights], stalls: drops, dropsWith: .networkConnectionLost))

        let snapshot = try await download(stub: stub, fixture: fixture)

        #expect(stub.ranges.count == dropCount + 1)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent(Self.weights.path)) == Self.weights.contents)
    }

    @Test("the backoff before each network retry is two times the backoff before the last retry")
    func networkBackoffDoubles() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let drops = Array(repeating: 0, count: Self.networkRetryLimit + 1)
        let stub = HubStub(
            .repository(commit: Self.commit, files: [Self.weights], stalls: drops, dropsWith: .timedOut))
        let clock = StallClock(stub: stub, retryLimit: Self.retryLimit, networkRetryLimit: Self.networkRetryLimit)

        let error = await #expect(throws: URLError.self) {
            try await download(stub: stub, fixture: fixture, clock: clock)
        }
        #expect(error?.code == .timedOut)
        #expect(clock.backoffs == [StallClock.initialBackoff, StallClock.initialBackoff * 2])
    }

    @Test("a network error that a new request cannot correct gets no retry")
    func permanentErrorGetsNoRetry() async throws {
        let fixture = try HubFixture(repository: Self.repository, commit: Self.commit)
        defer { fixture.remove() }
        let stub = HubStub(
            .repository(
                commit: Self.commit, files: [Self.weights], stalls: [Self.bytesBeforeDrop],
                dropsWith: .cannotDecodeContentData))

        let error = await #expect(throws: URLError.self) {
            try await download(stub: stub, fixture: fixture)
        }
        #expect(error?.code == .cannotDecodeContentData)
        #expect(stub.ranges == [nil])
    }

    @Test("the backoff does not get longer than the maximum backoff")
    func backoffStopsAtTheMaximum() {
        let policy = DownloadRetryPolicy(initialBackoff: .seconds(1), maximumBackoff: .seconds(5))

        #expect(
            (1...5).map(policy.backoff(beforeRetry:)) == [
                .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
            ])
    }

    @Test("only a URLError with a transient code is transient")
    func onlyTransientCodesAreTransient() {
        #expect(Self.transientCodes.allSatisfy { DownloadRetryPolicy.isTransient(URLError($0)) })
        #expect(!DownloadRetryPolicy.isTransient(URLError(.cancelled)))
        #expect(!DownloadRetryPolicy.isTransient(URLError(.badServerResponse)))
        #expect(!DownloadRetryPolicy.isTransient(CancellationError()))
    }

    /// Downloads the files of the patterns at the commit with the downloader
    /// of a source over the cache of `fixture`, whose requests go to `stub`.
    ///
    /// - Parameters:
    ///   - stub: The transport.
    ///   - fixture: The cache.
    ///   - clock: The clock of the retry policy, or `nil` for a new clock
    ///     over `stub`.
    /// - Returns: The snapshot folder that the download gives.
    /// - Throws: The error of the download.
    private func download(stub: HubStub, fixture: HubFixture, clock: StallClock? = nil) async throws -> URL {
        let clock =
            clock ?? StallClock(stub: stub, retryLimit: Self.retryLimit, networkRetryLimit: Self.networkRetryLimit)
        let source = HubSource(
            cache: fixture.cache, tokenProvider: .none, session: stub.session, retryPolicy: clock.policy)
        return try await source.downloader().download(
            id: Self.repository, revision: Self.commit, matching: Self.patterns, useLatest: false
        ) { stub.recordWritten($0.completedUnitCount) }
    }
}
