import Foundation
import HuggingFace

/// The Hugging Face cache and the token provider that a loader of
/// ``ModelPool`` downloads with: the one place that makes the hub client of a
/// download, and that finds a snapshot and a blob in the cache. ``MLXModelLoader``
/// and ``CoreMLModelLoader`` both use it, thus both read the same cache, the
/// same token and the same `HF_ENDPOINT`.
struct HubSource: Sendable {
    /// The environment variable that names the Hugging Face endpoint, as the
    /// Hugging Face client reads it.
    private static let endpointVariable = "HF_ENDPOINT"

    /// The Hugging Face cache that holds the downloaded files.
    let cache: HubCache

    /// The token provider of each download, which gives the Hugging Face
    /// token that the download sends.
    let tokenProvider: TokenProvider

    /// The Hugging Face client of each download. Its cache is the cache of the
    /// source, thus the download writes to the folder of the source. Its token
    /// comes from the token provider of the source.
    ///
    /// - Returns: A client over the cache and the token provider of the
    ///   source, at the host of ``host()``.
    func client() -> HubClient {
        HubClient(host: Self.host(), tokenProvider: tokenProvider, cache: cache)
    }

    /// The host of each download: the endpoint that `HF_ENDPOINT` names, or
    /// the Hugging Face Hub. The Hugging Face client reads this variable only
    /// in its init with no token provider, thus the source reads it for the
    /// init that takes one.
    ///
    /// - Returns: The URL of `HF_ENDPOINT`, or `HubClient.defaultHost` when
    ///   the variable is not set or is not a URL.
    static func host() -> URL {
        ProcessInfo.processInfo.environment[endpointVariable].flatMap { URL(string: $0) } ?? HubClient.defaultHost
    }

    /// Finds the snapshot folder of a model in the cache. The revision is a
    /// ref, such as `main`, that a ref file names, or a commit.
    ///
    /// - Parameters:
    ///   - repository: The Hugging Face repository id of the model.
    ///   - revision: The ref or the commit.
    /// - Returns: The snapshot folder, or `nil` when the cache holds no
    ///   snapshot of the revision.
    func snapshotDirectory(of repository: String, revision: String) -> URL? {
        guard let repo = Repo.ID(rawValue: repository) else { return nil }
        let commit = cache.resolveRevision(repo: repo, kind: .model, ref: revision) ?? revision
        guard let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit),
            FileManager.default.fileExists(atPath: snapshot.path)
        else { return nil }
        return snapshot
    }

    /// The size of the blob that a snapshot file links to.
    ///
    /// - Parameter file: A file of a snapshot.
    /// - Returns: The size of the blob, or `nil` when the file system gives no
    ///   size.
    /// - Throws: The error of the read of the file size.
    static func blobBytes(of file: URL) throws -> Int64? {
        let blob = file.resolvingSymlinksInPath()
        return try blob.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }
    }
}
