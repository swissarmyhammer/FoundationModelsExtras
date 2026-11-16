import Foundation
import Synchronization

/// A Hugging Face transport for the tests: a `URLSession` whose requests go to
/// ``HubStubProtocol``, which answers from this stub with no network. The stub
/// records the URL of each request, thus a test can prove which requests a
/// call made.
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
    /// The HTTP status of a tree listing.
    private static let okStatus = 200

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
        }
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
            let response = HTTPURLResponse(
                url: url, statusCode: Self.okStatus, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
