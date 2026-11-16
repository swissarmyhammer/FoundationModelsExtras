import Foundation
import Synchronization

/// A Hugging Face transport for the tests: a `URLSession` whose requests go to
/// ``HubStubProtocol``, which answers from this stub with no network. The stub
/// records the URL of each request, thus a test can prove which requests a
/// call made.
///
/// A stub of a ``Answer/repository(commit:files:)`` answers as the Hub does
/// for one commit: the model information, the tree listing, and the `HEAD`
/// and `GET` requests of each file, with the headers that the Hugging Face
/// client reads.
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
        case repository(commit: String, files: [TreeFile])
    }

    /// One file of the tree listing of a stub.
    struct TreeFile: Sendable {
        /// The size of the Git LFS pointer of an LFS file.
        private static let pointerSize = 134

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

        /// The bytes of the file: `size` zero bytes.
        var contents: Data {
            Data(repeating: 0, count: size)
        }

        /// The headers of a file request, as the Hub sends them: the commit,
        /// the size, and the etag. The Hub sends the etag of an LFS file as
        /// `X-Linked-Etag`, and the etag of another file as `ETag`.
        ///
        /// - Parameter commit: The commit of the revision.
        /// - Returns: The header fields.
        func headers(commit: String) -> [String: String] {
            let etagField = isLFS ? "X-Linked-Etag" : "ETag"
            return [
                "X-Repo-Commit": commit, etagField: "\"\(etag)\"", "Content-Length": String(size),
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

    /// The URL of each request, in order.
    private let recorded = Mutex<[URL]>([])

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
        recorded.withLock { $0 }
    }

    /// Finds the live stub with an identifier.
    ///
    /// - Parameter id: The identifier of the stub.
    /// - Returns: The stub, or `nil` when no live stub has the identifier.
    static func stub(withID id: String) -> HubStub? {
        live.withLock { $0[id] }
    }

    /// Records a request.
    ///
    /// - Parameter url: The URL of the request.
    func record(_ url: URL) {
        recorded.withLock { $0.append(url) }
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
        stub.record(url)
        switch stub.answer {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .tree(let files):
            answer(url: url, body: files.map(\.json))
        case .repository(let commit, let files):
            answerRepository(url: url, commit: commit, files: files)
        }
    }

    /// Answers a request to a repository at one commit: a file request with
    /// the file, a tree listing with the files, and each other request with
    /// the model information.
    ///
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - commit: The commit of the repository.
    ///   - files: The files of the repository.
    private func answerRepository(url: URL, commit: String, files: [HubStub.TreeFile]) {
        let components = url.pathComponents
        if let resolve = components.firstIndex(of: HubStub.resolveComponent) {
            let path = components.dropFirst(resolve + Self.revisionOffset).joined(separator: "/")
            answerFile(url: url, file: files.first { $0.path == path }, commit: commit)
        } else if components.contains(Self.treeComponent) {
            answer(url: url, body: files.map(\.json))
        } else {
            let repository = components.dropFirst(Self.repositoryOffset).prefix(Self.repositoryComponents)
            answer(url: url, body: ["id": repository.joined(separator: "/"), "sha": commit])
        }
    }

    /// Answers a file request: the headers of the file, and its bytes for a
    /// `GET`. A file that the repository does not hold gets the HTTP status
    /// of a missing file.
    ///
    /// - Parameters:
    ///   - url: The URL of the request.
    ///   - file: The file, or `nil` when the repository does not hold it.
    ///   - commit: The commit of the repository.
    private func answerFile(url: URL, file: HubStub.TreeFile?, commit: String) {
        guard let file else {
            send(url: url, status: Self.missingStatus, headers: [:], body: Data())
            return
        }
        let body = request.httpMethod == Self.headMethod ? Data() : file.contents
        send(url: url, status: Self.okStatus, headers: file.headers(commit: commit), body: body)
    }

    /// Does nothing: each answer is complete when ``startLoading()`` returns.
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
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
