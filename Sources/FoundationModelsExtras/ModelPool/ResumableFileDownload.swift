import Foundation
import HuggingFace

/// The download of one file of a Hub repository into its `.incomplete`
/// blob, which retries a stalled transfer from the bytes that the blob holds.
///
/// Each attempt sends one `GET` request of the file. When the blob holds
/// bytes, the request asks for the bytes after them with a
/// `Range: bytes=<bytes of the blob>-` header. A watch stops the attempt when
/// no bytes arrive for the stall interval of the ``DownloadRetryPolicy``. The
/// download then waits for the backoff of the policy and sends the next
/// attempt. After the retry limit of the policy, a stall throws
/// ``ModelDownloadError/stalled(repository:file:attempts:)``.
///
/// The bytes of the blob never decrease over a retry, thus the progress of
/// the download does not go backward. A server that ignores the range sends
/// the whole file again, and the blob then starts again from zero.
struct ResumableFileDownload: Sendable {
    /// The path component between the repository and the revision in the URL
    /// of a file.
    private static let resolveComponent = "resolve"

    /// The header of a request that asks for a part of a file.
    private static let rangeField = "Range"

    /// The header of the token of a request.
    private static let authorizationField = "Authorization"

    /// The session of each request.
    let session: URLSession

    /// The host of the Hub.
    let host: URL

    /// Gives the Hugging Face token of each request.
    let tokenProvider: TokenProvider

    /// The stall interval, the backoff and the retry limit.
    let policy: DownloadRetryPolicy

    /// Downloads a file of a repository into its `.incomplete` blob. When the
    /// method returns, the blob holds the whole file.
    ///
    /// - Parameters:
    ///   - path: The path of the file in the repository.
    ///   - repo: The repository.
    ///   - commit: The commit of the file.
    ///   - blob: The `.incomplete` blob of the file. Its bytes, when it
    ///     exists, are the start of the file.
    ///   - written: Gets the bytes of the blob after each write.
    /// - Throws: ``ModelDownloadError/stalled(repository:file:attempts:)``
    ///   when each attempt stalls, `CancellationError` when the task is
    ///   cancelled, or the error of the token, of a request or of a write.
    func download(
        _ path: String, of repo: Repo.ID, at commit: String, into blob: URL,
        written: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let request = try await request(of: path, in: repo, at: commit)
        var retry = 0
        while true {
            do {
                try await attempt(request, into: blob, written: written)
                return
            } catch FileTransfer.Failure.rangeNotSatisfiable {
                try FileManager.default.removeItem(at: blob)
            } catch FileTransfer.Failure.stalled {
                guard retry < policy.retryLimit else {
                    throw ModelDownloadError.stalled(repository: repo.rawValue, file: path, attempts: retry + 1)
                }
                retry += 1
                try await policy.sleep(policy.backoff(beforeRetry: retry))
            }
        }
    }

    /// The `GET` request of a file, with the token of the provider.
    ///
    /// - Parameters:
    ///   - path: The path of the file in the repository.
    ///   - repo: The repository.
    ///   - commit: The commit of the file.
    /// - Returns: The request.
    /// - Throws: The error of the token provider.
    private func request(of path: String, in repo: Repo.ID, at commit: String) async throws -> URLRequest {
        let url = host.appending(path: repo.namespace).appending(path: repo.name)
            .appending(path: Self.resolveComponent).appending(component: commit).appending(path: path)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token = try await tokenProvider.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: Self.authorizationField)
        }
        return request
    }

    /// Sends one request of the bytes after the bytes of the blob, and
    /// watches it.
    ///
    /// - Parameters:
    ///   - request: The request of the file.
    ///   - blob: The `.incomplete` blob of the file.
    ///   - written: Gets the bytes of the blob after each write.
    /// - Throws: ``FileTransfer/Failure/stalled`` when no bytes arrive for
    ///   the stall interval, `CancellationError` when the task is cancelled,
    ///   or the error of the transfer.
    private func attempt(
        _ request: URLRequest, into blob: URL, written: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let offset = Self.size(of: blob)
        var request = request
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: Self.rangeField) }
        let transfer = FileTransfer(blob: blob, offset: offset, written: written)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [session, request] in try await transfer.run(in: session, request: request) }
                group.addTask { try await watch(transfer) }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    /// Watches a transfer until no bytes arrive for the stall interval. The
    /// transfer ends the watch with a cancel when it completes first.
    ///
    /// - Parameter transfer: The transfer.
    /// - Throws: ``FileTransfer/Failure/stalled`` when no bytes arrive for the
    ///   stall interval, or the error of the sleep of the policy, for example
    ///   `CancellationError`.
    private func watch(_ transfer: FileTransfer) async throws {
        var lastBytes = transfer.receivedBytes
        while true {
            try await policy.sleep(policy.stallInterval)
            let bytes = transfer.receivedBytes
            guard bytes != lastBytes else { throw FileTransfer.Failure.stalled }
            lastBytes = bytes
        }
    }

    /// The bytes of a file.
    ///
    /// - Parameter file: The file.
    /// - Returns: The size of the file, or 0 when it does not exist.
    static func size(of file: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

/// A failure of the download of a model file.
public enum ModelDownloadError: Error, Equatable, LocalizedError {
    /// No bytes of the file arrived for the stall interval, in each attempt:
    /// the first attempt and each retry.
    case stalled(repository: String, file: String, attempts: Int)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .stalled(let repository, let file, let attempts):
            return "The download of \(file) from \(repository) stalled: no bytes arrived in each of \(attempts) attempts."
        }
    }
}
