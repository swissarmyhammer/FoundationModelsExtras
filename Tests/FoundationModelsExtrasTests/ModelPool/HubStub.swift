import Foundation
import Synchronization

/// A Hugging Face transport for the tests: a `URLSession` whose requests go to
/// ``HubStubProtocol``, which answers from this stub with no network. The stub
/// records the URL of each request, thus a test can prove which requests a
/// call made.
///
/// A stub of a ``Answer/repository(commit:files:stalls:redirect:)`` answers as
/// the Hub does for one commit: the model information, the tree listing, and
/// the `HEAD` and `GET` requests of each file, with the headers that the
/// Hugging Face client reads. A `GET` with a `Range` header gets the bytes from
/// the start of the range. A `GET` can also stall: it sends some bytes, and
/// then it sends nothing more until the client stops it. A `GET` can also get
/// a redirect to the same file at another URL, as the Hub sends a file request
/// to its CDN.
///
/// Each stub has its own identifier. Its session sends the identifier in the
/// ``header`` header of each request, thus tests that run at the same time
/// each get the answers of their own stub.
final class HubStub: Sendable {
    /// The answer of the stub to each request.
    enum Answer: Sendable {
        /// The tree listing of the repository, with these files.
        case tree([TreeFile])
        /// No network: each request fails with `URLError.notConnectedToInternet`.
        case offline
        /// The repository at `commit`, with these files: the model
        /// information gives the commit, the tree listing gives the files,
        /// and a file request gives the headers and the bytes of the file.
        ///
        /// `stalls` holds the bytes that the first `GET` requests of a file
        /// send before they stall: the first `GET` sends `stalls[0]` bytes,
        /// the second `stalls[1]` bytes, and so on. A stalled request then
        /// sends nothing more until the client stops it. Each `GET` after
        /// the last stall sends all its bytes. A `GET` whose range the stub
        /// refuses sends no bytes, thus it does not count.
        ///
        /// When `redirect` is not `nil`, a `GET` of a file at a URL that is
        /// not under `redirect` gets a redirect to the same path under
        /// `redirect`. The redirected request holds each header of the first
        /// request, as the URL session makes it for an HTTP redirect.
        case repository(commit: String, files: [TreeFile], stalls: [Int] = [], redirect: URL? = nil)
    }

    /// The state of a wait for a stall when the wait starts.
    private enum WaitStart {
        /// The stall is reached: the wait is over at once.
        case reached
        /// The task waits until the stall is reached.
        case waiting
        /// The task is cancelled: the wait ends with `CancellationError`.
        case cancelled
    }

    /// The stalls of the `GET` requests of a file, and the bytes that the
    /// download wrote, with the tasks that wait for a stall.
    private struct StallState {
        /// The `GET` requests of a file that the stub answered with bytes.
        var fileRequests = 0

        /// The end of the bytes that each stalled request sent, as an offset
        /// in its file, in the order of the stalls.
        var stallEnds: [Int64] = []

        /// The bytes that the download wrote, as the test last saw them.
        var writtenBytes: Int64 = 0

        /// The tasks that wait for a stall, by identifier, with the number of
        /// the stall that each waits for.
        var waiters: [UUID: (stall: Int, continuation: CheckedContinuation<Void, any Error>)] = [:]

        /// Whether stall `number` occurred and the download wrote each byte
        /// that its request sent.
        ///
        /// - Parameter number: The number of the stall, from 1.
        /// - Returns: `true` when the wait for the stall is over.
        func isReached(stall number: Int) -> Bool {
            stallEnds.count >= number && writtenBytes >= stallEnds[number - 1]
        }

        /// Removes each waiter whose stall is reached.
        ///
        /// - Returns: The continuations of the removed waiters.
        mutating func takeReachedWaiters() -> [CheckedContinuation<Void, any Error>] {
            let reached = waiters.filter { isReached(stall: $0.value.stall) }
            for id in reached.keys { waiters[id] = nil }
            return reached.values.map(\.continuation)
        }
    }

    /// One file of the tree listing of a stub.
    struct TreeFile: Sendable {
        /// The size of the Git LFS pointer of an LFS file.
        private static let pointerSize = 134

        /// The header of the number of bytes of an answer.
        static let lengthField = "Content-Length"

        /// The path of the file, relative to the root of the repository.
        let path: String

        /// The size of the file, in bytes.
        let size: Int

        /// `true` when the Hub keeps the file with Git LFS.
        let isLFS: Bool

        /// The etag of the file: the name of its blob in the cache.
        var etag: String {
            "etag-" + path.replacingOccurrences(of: "/", with: "-")
        }

        /// The number of different byte values of ``contents``. It is a prime
        /// number, thus the pattern of the bytes does not repeat at a power
        /// of two, and a byte at a wrong offset gives a different file.
        private static let byteValues = 251

        /// The bytes of the file: `size` bytes, each the remainder of its
        /// offset divided by ``byteValues``.
        var contents: Data {
            Data((0..<size).map { UInt8($0 % Self.byteValues) })
        }

        /// The headers of a file request, as the Hub sends them: the commit,
        /// the size, the etag, and the content type. The Hub sends the etag
        /// of an LFS file as `X-Linked-Etag`, and the etag of another file as
        /// `ETag`. With no content type, the URL session keeps the first
        /// bytes of an answer to find the type, thus a stalled answer would
        /// give no bytes to the client.
        ///
        /// - Parameter commit: The commit of the revision.
        /// - Returns: The header fields.
        func headers(commit: String) -> [String: String] {
            let etagField = isLFS ? "X-Linked-Etag" : "ETag"
            return [
                "X-Repo-Commit": commit, etagField: "\"\(etag)\"", Self.lengthField: String(size),
                "Content-Type": "application/octet-stream",
            ]
        }

        /// The JSON object of the file in a tree listing of the Hub. An LFS
        /// file has the etag as its LFS object id, and the size of its
        /// pointer as its Git size. Another file has the etag as its Git
        /// object id.
        var json: [String: Any] {
            guard isLFS else { return ["type": "file", "path": path, "oid": etag, "size": size] }
            return [
                "type": "file", "path": path, "oid": "git-" + etag, "size": Self.pointerSize,
                "lfs": ["oid": etag, "size": size, "pointerSize": Self.pointerSize],
            ]
        }
    }

    /// The header that carries the identifier of the stub.
    static let header = "X-Hub-Stub"

    /// The path component that starts the path of a file request:
    /// `/<repository>/resolve/<revision>/<file>`.
    static let resolveComponent = "resolve"

    /// The live stubs, by identifier. A stub stays here until the test
    /// process ends: each stub is small, and a test makes few of them.
    private static let live = Mutex<[String: HubStub]>([:])

    /// The identifier of the stub.
    let id = UUID().uuidString

    /// The answer of the stub to each request.
    let answer: Answer

    /// Each request, in order.
    private let recorded = Mutex<[URLRequest]>([])

    /// The `Range` header of each `GET` request of a file, in order: `nil`
    /// for a request with no `Range` header.
    private let recordedRanges = Mutex<[String?]>([])

    /// The stalls, the written bytes, and the tasks that wait for a stall.
    private let stallState = Mutex(StallState())

    /// Makes a stub, and registers it.
    ///
    /// - Parameter answer: The answer to each request.
    init(_ answer: Answer) {
        self.answer = answer
        Self.live.withLock { [id] in $0[id] = self }
    }

    /// A session whose requests go to this stub.
    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubStubProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        return URLSession(configuration: configuration)
    }

    /// The URL of each request that the stub got, in order.
    var requests: [URL] {
        recorded.withLock { $0.compactMap(\.url) }
    }

    /// The value of a header in each request to a host, in order: `nil` for
    /// a request with no such header.
    ///
    /// - Parameters:
    ///   - field: The name of the header.
    ///   - host: The host of the requests.
    /// - Returns: The values of the header.
    func headerValues(_ field: String, ofRequestsTo host: String?) -> [String?] {
        recorded.withLock { requests in
            requests.filter { $0.url?.host == host }.map { $0.value(forHTTPHeaderField: field) }
        }
    }

    /// Finds the live stub with an identifier.
    ///
    /// - Parameter id: The identifier of the stub.
    /// - Returns: The stub, or `nil` when no live stub has the identifier.
    static func stub(withID id: String) -> HubStub? {
        live.withLock { $0[id] }
    }

    /// The `Range` header of each `GET` request of a file that the stub got,
    /// in order: `nil` for a request with no `Range` header.
    var ranges: [String?] {
        recordedRanges.withLock { $0 }
    }

    /// Records a request.
    ///
    /// - Parameter request: The request.
    func record(_ request: URLRequest) {
        recorded.withLock { $0.append(request) }
    }

    /// Records the `Range` header of a `GET` request of a file.
    ///
    /// - Parameter range: The `Range` header of the request, or `nil`.
    func recordRange(_ range: String?) {
        recordedRanges.withLock { $0.append(range) }
    }

    /// Tells whether the next `GET` request of a file that sends bytes
    /// stalls.
    ///
    /// - Parameter stalls: The bytes that the first `GET` requests send
    ///   before they stall.
    /// - Returns: The bytes that the request sends before it stalls, or `nil`
    ///   when it sends all its bytes.
    func nextStall(of stalls: [Int]) -> Int? {
        let index = stallState.withLock { state in
            defer { state.fileRequests += 1 }
            return state.fileRequests
        }
        return stalls.indices.contains(index) ? stalls[index] : nil
    }

    /// Records that a request stalled, and ends the wait of each task that
    /// waits for it.
    ///
    /// - Parameter end: The end of the bytes that the request sent, as an
    ///   offset in its file.
    func recordStall(end: Int64) {
        resumeReachedWaiters { $0.stallEnds.append(end) }
    }

    /// Records the bytes that the download wrote, and ends the wait of each
    /// task whose stall is reached. A test calls it from the progress handler
    /// of the download.
    ///
    /// - Parameter bytes: The completed bytes of the download.
    func recordWritten(_ bytes: Int64) {
        resumeReachedWaiters { $0.writtenBytes = max($0.writtenBytes, bytes) }
    }

    /// Changes the stall state, and ends the wait of each task whose stall
    /// the change reached.
    ///
    /// - Parameter update: The change of the state.
    private func resumeReachedWaiters(_ update: (inout StallState) -> Void) {
        let reached = stallState.withLock { state in
            update(&state)
            return state.takeReachedWaiters()
        }
        for continuation in reached { continuation.resume() }
    }

    /// Waits until stall `number` occurred and the download wrote each byte
    /// that its request sent. The wait needs no clock: only a stall and the
    /// writes of the download end it.
    ///
    /// - Parameter number: The number of the stall, from 1.
    /// - Throws: `CancellationError` when the task is cancelled first.
    func waitForStall(number: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let start: WaitStart = stallState.withLock { state in
                    if state.isReached(stall: number) { return .reached }
                    if Task.isCancelled { return .cancelled }
                    state.waiters[id] = (number, continuation)
                    return .waiting
                }
                switch start {
                case .reached: continuation.resume()
                case .waiting: break
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter = stallState.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// The URL protocol of ``HubStub``: it answers each request from the stub that
/// the ``HubStub/header`` header names.
final class HubStubProtocol: URLProtocol {
    /// The HTTP status of an answer.
    private static let okStatus = 200

    /// The HTTP status of a request for a file that the repository does not
    /// hold.
    private static let missingStatus = 404

    /// The HTTP status of a redirect to the same file at another URL.
    private static let redirectStatus = 302

    /// The header of a redirect that names the new URL.
    private static let locationField = "Location"

    /// The HTTP status of an answer that holds a part of a file.
    private static let partialStatus = 206

    /// The HTTP status of a range that starts at the end of the file or
    /// after it.
    private static let rangeNotSatisfiableStatus = 416

    /// The header of a request that asks for a part of a file.
    private static let rangeField = "Range"

    /// The start of a `Range` header of the form `bytes=<start>-`.
    private static let rangePrefix = "bytes="

    /// The header of an answer that names the part of the file that it
    /// holds.
    private static let contentRangeField = "Content-Range"

    /// The method of a request for the headers of a file only.
    private static let headMethod = "HEAD"

    /// The path component of a tree listing:
    /// `/api/models/<repository>/tree/<revision>`.
    private static let treeComponent = "tree"

    /// The path components between `resolve` and the path of the file: the
    /// component `resolve` itself and the revision.
    private static let revisionOffset = 2

    /// The path components before the repository in a model information
    /// request: `/`, `api` and `models`.
    private static let repositoryOffset = 3

    /// The path components of a repository id: the namespace and the name.
    private static let repositoryComponents = 2

    /// Takes each request.
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    /// Gives the request as it is.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Answers the request from its stub, or fails it when no stub is live.
    override func startLoading() {
        guard let url = request.url, let id = request.value(forHTTPHeaderField: HubStub.header),
            let stub = HubStub.stub(withID: id)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        stub.record(request)
        switch stub.answer {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .tree(let files):
            answer(url: url, body: files.map(\.json))
        case .repository(let commit, let files, let stalls, let redirect):
            if let target = Self.redirectTarget(of: request, under: redirect) {
                answerRedirect(to: target)
            } else {
                answerRepository(url: url, commit: commit, files: files, stalls: stalls, stub: stub)
            }
        }
    }

    /// The URL of the redirect of a `GET` of a file: the same path under
    /// `redirect`.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - redirect: The base URL of each redirect, or `nil` for no redirect.
    /// - Returns: The URL of the redirect, or `nil` when the request gets no
    ///   redirect: it is not a `GET` of a file, or it is under `redirect`.
    private static func redirectTarget(of request: URLRequest, under redirect: URL?) -> URL? {
        guard let redirect, let url = request.url, request.httpMethod != headMethod,
            url.pathComponents.contains(HubStub.resolveComponent),
            !url.absoluteString.hasPrefix(redirect.absoluteString)
        else { return nil }
        return redirect.appending(path: url.path)
    }

    /// Sends a redirect to `target`. The new request holds each header of
    /// the request, as the URL session makes it for an HTTP redirect.
    ///
    /// - Parameter target: The URL of the redirect.
    private func answerRedirect(to target: URL) {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: Self.redirectStatus, httpVersion: nil,
                headerFields: [Self.locationField: target.absoluteString])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var redirected = request
        redirected.url = target
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
    }

    /// Answers a request to a repository at one commit: a file request with
    /// the file, a tree listing with the files, and each other request with
    /// the model information.
    ///
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - commit: The commit of the repository.
    ///   - files: The files of the repository.
    ///   - stalls: The bytes that the first `GET` requests of a file send
    ///     before they stall.
    ///   - stub: The stub that records the requests and the stalls.
    private func answerRepository(
        url: URL, commit: String, files: [HubStub.TreeFile], stalls: [Int], stub: HubStub
    ) {
        let components = url.pathComponents
        if let resolve = components.firstIndex(of: HubStub.resolveComponent) {
            let path = components.dropFirst(resolve + Self.revisionOffset).joined(separator: "/")
            guard let file = files.first(where: { $0.path == path }) else {
                send(url: url, status: Self.missingStatus, headers: [:], body: Data())
                return
            }
            answerFile(url: url, file: file, commit: commit, stalls: stalls, stub: stub)
        } else if components.contains(Self.treeComponent) {
            answer(url: url, body: files.map(\.json))
        } else {
            let repository = components.dropFirst(Self.repositoryOffset).prefix(Self.repositoryComponents)
            answer(url: url, body: ["id": repository.joined(separator: "/"), "sha": commit])
        }
    }

    /// Answers a file request: the headers of the file, and its bytes for a
    /// `GET`. A `GET` with a `Range` header gets the bytes from the start of
    /// the range, with the HTTP status of a partial answer, or the HTTP
    /// status of a range that the server cannot give when the range starts
    /// at the end of the file or after it. A `GET` that stalls sends its
    /// first bytes and then nothing more.
    ///
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - file: The file.
    ///   - commit: The commit of the repository.
    ///   - stalls: The bytes that the first `GET` requests of a file send
    ///     before they stall.
    ///   - stub: The stub that records the request and the stall.
    private func answerFile(
        url: URL, file: HubStub.TreeFile, commit: String, stalls: [Int], stub: HubStub
    ) {
        guard request.httpMethod != Self.headMethod else {
            send(url: url, status: Self.okStatus, headers: file.headers(commit: commit), body: Data())
            return
        }
        let range = request.value(forHTTPHeaderField: Self.rangeField)
        stub.recordRange(range)
        let start = Self.rangeStart(of: range) ?? 0
        guard start == 0 || start < file.size else {
            send(url: url, status: Self.rangeNotSatisfiableStatus, headers: [:], body: Data())
            return
        }
        let stall = stub.nextStall(of: stalls)
        let body = file.contents.subdata(in: start..<file.size)
        let status = start > 0 ? Self.partialStatus : Self.okStatus
        var headers = file.headers(commit: commit)
        headers[HubStub.TreeFile.lengthField] = String(body.count)
        if start > 0 { headers[Self.contentRangeField] = "bytes \(start)-\(file.size - 1)/\(file.size)" }
        guard let stall else {
            send(url: url, status: status, headers: headers, body: body)
            return
        }
        let sent = body.prefix(stall)
        startAnswer(url: url, status: status, headers: headers, body: sent)
        stub.recordStall(end: Int64(start + sent.count))
    }

    /// The first byte of a `Range` header of the form `bytes=<start>-`.
    ///
    /// - Parameter range: The header, or `nil`.
    /// - Returns: The start, or `nil` when there is no header or it has
    ///   another form.
    private static func rangeStart(of range: String?) -> Int? {
        guard let range, range.hasPrefix(rangePrefix), range.hasSuffix("-") else { return nil }
        return Int(range.dropFirst(rangePrefix.count).dropLast())
    }

    /// Does nothing: a complete answer is over when ``startLoading()``
    /// returns, and a stalled answer sends nothing more.
    override func stopLoading() {}

    /// Sends a JSON body with the HTTP status of success.
    ///
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - body: The JSON value of the body.
    private func answer(url: URL, body: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            send(url: url, status: Self.okStatus, headers: ["Content-Type": "application/json"], body: data)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// Sends a complete response.
    ///
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - status: The HTTP status.
    ///   - headers: The header fields.
    ///   - body: The body.
    private func send(url: URL, status: Int, headers: [String: String], body: Data) {
        startAnswer(url: url, status: status, headers: headers, body: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Sends the response and the bytes of `body`, and does not finish the
    /// answer.
    ///
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - status: The HTTP status.
    ///   - headers: The header fields.
    ///   - body: The bytes to send.
    private func startAnswer(url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: body)
    }
}
