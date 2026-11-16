import Foundation
import HuggingFace
import Synchronization

/// One request of the bytes of a file: it writes each chunk to the
/// `.incomplete` blob of the file as the chunk arrives. Thus when the request
/// stops before its end, the blob keeps each byte that arrived, and the next
/// request can ask for the bytes after them.
///
/// The transfer counts the bytes that it received, thus a watch can see when
/// no bytes arrive. No error of a close of the blob is lost: when the
/// transfer gives no other failure, the close error is the outcome of the
/// transfer, and else the transfer writes a log record with its error type.
///
/// A redirect to a host that is not the host of the request gets no
/// `Authorization` header, thus the token goes only to the host of the
/// request.
final class FileTransfer: NSObject, URLSessionDataDelegate, Sendable {
    /// A failure of a transfer that the download handles with a new request.
    enum Failure: Error {
        /// No bytes arrived for the stall interval. The watch of the transfer
        /// gives this failure.
        case stalled
        /// The server cannot give the range after the bytes of the blob.
        case rangeNotSatisfiable
    }

    /// Where the bytes of the answer go.
    private enum Sink {
        /// No answer arrived yet.
        case none
        /// The answer holds the bytes of the file: they go to the blob.
        case file(any BlobWriter, startOffset: Int64)
        /// The answer is an HTTP error: its body is the detail of the error.
        case errorBody(HTTPURLResponse, Data)
        /// The answer cannot be used, and the transfer stops with `error`.
        case failed(any Error)
    }

    /// The mutable state of the transfer, which the lock guards.
    private struct State {
        /// The data task, or `nil` before the start.
        var task: URLSessionDataTask?
        /// Whether the task of the transfer was cancelled.
        var isCancelled = false
        /// Resumes the caller of ``run(in:request:)`` when the task ends.
        var continuation: CheckedContinuation<Void, any Error>?
        /// Where the bytes of the answer go.
        var sink = Sink.none
        /// The bytes of the file that this request received.
        var receivedBytes: Int64 = 0
        /// The errors of the closes of the blob that the outcome of the
        /// transfer does not give. The run writes a log record for each.
        var closeFailures: [any Error] = []

        /// Sets the sink of the answer. When the sink before it writes to
        /// the blob, it closes the blob first, thus no open blob stays after
        /// the sink changes, and a later request can open the blob again.
        /// The new sink gives the outcome of the transfer, thus the error of
        /// that close goes to ``closeFailures``.
        ///
        /// - Parameter sink: The new sink.
        mutating func replaceSink(with sink: Sink) {
            if case .file(let writer, _) = self.sink { close(writer) }
            self.sink = sink
        }

        /// Closes the blob, and keeps the error of the close in
        /// ``closeFailures``.
        ///
        /// - Parameter writer: The blob.
        mutating func close(_ writer: any BlobWriter) {
            do {
                try writer.close()
            } catch {
                closeFailures.append(error)
            }
        }

        /// The outcome of the transfer when its task ended. Closes the blob.
        /// When the task ended with an error, that error is the outcome, and
        /// the error of the close goes to ``closeFailures``.
        ///
        /// - Parameter error: The error of the task, or `nil` when it
        ///   completed.
        /// - Returns: Success, or the failure of the transfer.
        mutating func outcome(error: (any Error)?) -> Result<Void, any Error> {
            switch sink {
            case .failed(let failure):
                return .failure(failure)
            case .errorBody(let response, let body):
                return .failure(
                    HTTPClientError.responseError(response: response, detail: String(decoding: body, as: UTF8.self)))
            case .file(let writer, _):
                if let error {
                    close(writer)
                    return .failure(error)
                }
                return Result { try writer.close() }
            case .none:
                return .failure(error ?? URLError(.badServerResponse))
            }
        }

        /// Takes the errors of the closes that the outcome does not give.
        ///
        /// - Returns: The errors, in order.
        mutating func takeCloseFailures() -> [any Error] {
            defer { closeFailures = [] }
            return closeFailures
        }
    }

    /// The HTTP status of an answer that holds a part of the file.
    static let partialStatus = 206

    /// The HTTP status of a range that the server cannot give.
    static let rangeNotSatisfiableStatus = 416

    /// The HTTP statuses of success.
    private static let successStatuses = 200..<300

    /// The header of the token of a request.
    static let authorizationField = "Authorization"

    /// The `.incomplete` blob of the file.
    private let blob: URL

    /// The bytes of the blob before the request: the start of the range that
    /// the request asks for.
    private let offset: Int64

    /// Gets the bytes of the blob after each write.
    private let written: @Sendable (Int64) -> Void

    /// Opens the blob for writes after the bytes to keep.
    private let openBlob: @Sendable (URL, Int64) throws -> any BlobWriter

    /// The state of the transfer.
    private let state = Mutex(State())

    /// Makes a transfer into `blob`.
    ///
    /// - Parameters:
    ///   - blob: The `.incomplete` blob of the file.
    ///   - offset: The bytes of the blob before the request. A partial answer
    ///     writes after them, and a complete answer writes over them.
    ///   - written: Gets the bytes of the blob after each write. It runs on
    ///     the delegate queue of the session.
    ///   - openBlob: Opens the blob for writes after the bytes to keep: it
    ///     gets the blob and the bytes to keep. The default opens the file
    ///     with ``openFile(_:at:)``.
    init(
        blob: URL, offset: Int64, written: @escaping @Sendable (Int64) -> Void,
        openBlob: @escaping @Sendable (URL, Int64) throws -> any BlobWriter = openFile
    ) {
        self.blob = blob
        self.offset = offset
        self.written = written
        self.openBlob = openBlob
    }

    /// The bytes of the file that this request received.
    var receivedBytes: Int64 {
        state.withLock { $0.receivedBytes }
    }

    /// Sends `request` and writes the bytes of the answer to the blob.
    ///
    /// - Parameters:
    ///   - session: The session of the request.
    ///   - request: The request of the file.
    /// When the run ends, it writes a log record for each error of a close
    /// of the blob that it does not throw. It writes the records in the task
    /// of the caller, thus they get the logging context of the caller.
    ///
    /// - Throws: ``Failure/rangeNotSatisfiable`` when the server cannot give
    ///   the range, `HTTPClientError.responseError` for another
    ///   HTTP error, `CancellationError` when the task is cancelled before the
    ///   request starts, or the error of the request, of a write or of the
    ///   close of the blob.
    func run(in session: URLSession, request: URLRequest) async throws {
        defer {
            for failure in state.withLock({ $0.takeCloseFailures() }) {
                PoolTelemetry.logBlobCloseFailure(failure)
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            let task = state.withLock { state in
                state.isCancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    /// Starts `task`, or ends the run at once when the task of the caller is
    /// already cancelled.
    ///
    /// - Parameters:
    ///   - task: The data task of the request.
    ///   - continuation: Resumes the caller when the task ends.
    private func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, any Error>) {
        task.delegate = self
        let isCancelled = state.withLock { state in
            guard !state.isCancelled else { return true }
            state.task = task
            state.continuation = continuation
            return false
        }
        guard !isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        task.resume()
    }

    /// Opens the blob for the bytes of a successful answer, or keeps the
    /// detail of an error.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let sink = sink(for: response)
        state.withLock { $0.replaceSink(with: sink) }
        guard case .failed = sink else {
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
    }

    /// Writes a chunk of the file to the blob, or keeps a chunk of the
    /// detail of an error.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let blobBytes = state.withLock { state in
            Self.take(data, into: &state)
        }
        guard let blobBytes else { return }
        written(blobBytes)
    }

    /// Follows a redirect, and removes the token from the new request when
    /// the redirect goes to a host that is not the host of the first
    /// request. The Hub sends a file request to a CDN on another host, and
    /// the token must not go to that host. Each other header, for example
    /// the `Range` header, stays.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirected(request, from: task.originalRequest))
    }

    /// The new request of a redirect: with no token when its host is not the
    /// host of the first request.
    ///
    /// - Parameters:
    ///   - request: The new request that the session made for the redirect.
    ///   - original: The first request of the task.
    /// - Returns: The request to send.
    private static func redirected(_ request: URLRequest, from original: URLRequest?) -> URLRequest {
        guard !isSameHost(request.url, original?.url) else { return request }
        var request = request
        request.setValue(nil, forHTTPHeaderField: authorizationField)
        return request
    }

    /// Whether two URLs have the same host. A host name is not case
    /// sensitive.
    ///
    /// - Parameters:
    ///   - url: A URL.
    ///   - other: The other URL.
    /// - Returns: `true` when both URLs have a host and the hosts are the
    ///   same.
    private static func isSameHost(_ url: URL?, _ other: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), let otherHost = other?.host?.lowercased() else { return false }
        return host == otherHost
    }

    /// Keeps the answer out of the URL cache: the blob holds the file.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

    /// Closes the blob and ends the run with the outcome of the transfer.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, outcome) = state.withLock { state in
            let outcome = state.outcome(error: error)
            let continuation = state.continuation
            state.sink = .none
            state.continuation = nil
            return (continuation, outcome)
        }
        continuation?.resume(with: outcome)
    }

    /// Where the bytes of `response` go: the blob for a success, the detail
    /// of an error for an HTTP error, or a failure for an answer that cannot
    /// be used.
    ///
    /// A partial answer to a request with a range writes after the bytes of
    /// the blob. Each other success writes the whole file over the blob, for
    /// example when the server ignores the range.
    ///
    /// - Parameter response: The answer of the server.
    /// - Returns: The sink of the answer.
    private func sink(for response: URLResponse) -> Sink {
        guard let response = response as? HTTPURLResponse else { return .failed(URLError(.badServerResponse)) }
        if response.statusCode == Self.rangeNotSatisfiableStatus, offset > 0 {
            return .failed(Failure.rangeNotSatisfiable)
        }
        guard Self.successStatuses.contains(response.statusCode) else { return .errorBody(response, Data()) }
        let startOffset = response.statusCode == Self.partialStatus ? offset : 0
        do {
            return .file(try openBlob(blob, startOffset), startOffset: startOffset)
        } catch {
            return .failed(error)
        }
    }

    /// Opens a blob for writes at `offset`, and removes each byte after it.
    ///
    /// - Parameters:
    ///   - blob: The blob. It is made when it does not exist.
    ///   - offset: The bytes of the blob to keep.
    /// - Returns: A handle that writes after the kept bytes.
    /// - Throws: The error of the open or of the truncation.
    static func openFile(_ blob: URL, at offset: Int64) throws -> any BlobWriter {
        if !FileManager.default.fileExists(atPath: blob.path) {
            FileManager.default.createFile(atPath: blob.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: blob)
        try handle.truncate(atOffset: UInt64(offset))
        return handle
    }

    /// Takes a chunk of the answer into its sink.
    ///
    /// - Parameters:
    ///   - data: The chunk.
    ///   - state: The state of the transfer.
    /// - Returns: The bytes of the blob after a write, or `nil` when the
    ///   chunk did not go to the blob.
    private static func take(_ data: Data, into state: inout State) -> Int64? {
        switch state.sink {
        case .file(let writer, let startOffset):
            do {
                try writer.append(data)
            } catch {
                state.replaceSink(with: .failed(error))
                state.task?.cancel()
                return nil
            }
            state.receivedBytes += Int64(data.count)
            return startOffset + state.receivedBytes
        case .errorBody(let response, let body):
            state.sink = .errorBody(response, body + data)
            return nil
        case .none, .failed:
            return nil
        }
    }
}

/// Writes the bytes of a blob, in order, after the bytes that it keeps.
protocol BlobWriter: AnyObject, Sendable {
    /// Writes bytes after the bytes that the blob holds.
    ///
    /// - Parameter data: The bytes.
    /// - Throws: The error of the write.
    func append(_ data: Data) throws

    /// Closes the blob. No write follows.
    ///
    /// - Throws: The error of the close.
    func close() throws
}

extension FileHandle: BlobWriter {
    /// Writes bytes at the offset of the handle.
    ///
    /// - Parameter data: The bytes.
    /// - Throws: The error of the write.
    func append(_ data: Data) throws {
        try write(contentsOf: data)
    }
}
