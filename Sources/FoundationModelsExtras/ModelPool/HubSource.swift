import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon

/// The Hugging Face cache and the token provider that a loader of
/// ``ModelPool`` downloads with: the one place that makes the hub client of a
/// download, and that finds a snapshot and a blob in the cache. ``MLXModelLoader``
/// and ``CoreMLModelLoader`` both use it, thus both read the same cache, the
/// same token and the same `HF_ENDPOINT`.
struct HubSource: Sendable {
    /// The environment variable that names the Hugging Face endpoint, as the
    /// Hugging Face client reads it.
    private static let endpointVariable = "HF_ENDPOINT"

    /// The number of characters of a Git commit id.
    private static let commitLength = 40

    /// The Hugging Face cache that holds the downloaded files.
    let cache: HubCache

    /// The token provider of each download, which gives the Hugging Face
    /// token that the download sends.
    let tokenProvider: TokenProvider

    /// The URL session of each request of the hub client. A test gives a
    /// session whose requests go to a stub, thus the test needs no network.
    var session = URLSession(configuration: .default)

    /// The Hugging Face client of each download. Its cache is the cache of the
    /// source, thus the download writes to the folder of the source. Its token
    /// comes from the token provider of the source.
    ///
    /// - Returns: A client over the session, the cache and the token
    ///   provider of the source, at the host of ``host()``.
    func client() -> HubClient {
        HubClient(session: session, host: Self.host(), tokenProvider: tokenProvider, cache: cache)
    }

    /// The downloader of each snapshot download of a loader. Before the
    /// Hugging Face download, it links each file of the revision whose blob
    /// the cache holds, thus a file with the same hash as a cached file does
    /// not download again after the revision changes. See
    /// ``BlobReusingDownloader``.
    ///
    /// - Returns: A downloader over a new client of the source.
    func downloader() -> any Downloader {
        let client = client()
        return BlobReusingDownloader(client: client, cache: cache, upstream: #hubDownloader(client))
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

    /// Finds the folder that holds the files of a model: the local folder when
    /// the reference names one, else the snapshot folder in the cache. This is
    /// the one place that decides where the files of a model are, thus each
    /// loader finds the same folder for the same reference.
    ///
    /// - Parameters:
    ///   - ref: The reference of the model.
    ///   - revision: The ref or the commit of the cache snapshot. A local
    ///     folder ignores it.
    /// - Returns: The folder, or `nil` when the reference is not local and the
    ///   cache holds no snapshot of the revision.
    func modelFolder(of ref: ModelRef, revision: String) -> URL? {
        ref.localDirectory ?? snapshotDirectory(of: ref.repo, revision: revision)
    }

    /// The paths of the files in `folder` at any depth, relative to it. A
    /// symbolic link of a snapshot counts as a file.
    ///
    /// - Parameter folder: The folder.
    /// - Returns: The paths, or none when the folder cannot be read.
    static func relativePaths(in folder: URL) -> [String] {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        return enumerator.compactMap { $0 as? String }.filter { relative in
            var isFolder: ObjCBool = false
            let full = (root as NSString).appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: full, isDirectory: &isFolder) && !isFolder.boolValue
                || (relative as NSString).pathExtension == "mlpackage"
        }
    }

    /// The paths that match a pattern of a snapshot download, as the Hugging
    /// Face downloader matches them: with `fnmatch` and no flags. No pattern
    /// matches each path.
    ///
    /// - Parameters:
    ///   - paths: Paths relative to the root of a repository.
    ///   - patterns: The patterns of the download.
    /// - Returns: The paths that match a pattern, in their order.
    static func paths(_ paths: [String], matching patterns: [String]) -> [String] {
        guard !patterns.isEmpty else { return paths }
        return paths.filter { path in patterns.contains { fnmatch($0, path, 0) == 0 } }
    }

    /// Whether a revision is a Git commit id: 40 hexadecimal characters, as
    /// the Hugging Face cache names a snapshot.
    ///
    /// - Parameter revision: A ref or a commit.
    /// - Returns: `true` for a commit id.
    static func isCommit(_ revision: String) -> Bool {
        revision.count == commitLength && revision.allSatisfy(\.isHexDigit)
    }

    /// The paths that are `path` or are under it.
    ///
    /// - Parameters:
    ///   - paths: Paths relative to a root.
    ///   - path: A path inside the root, or `nil` for the root.
    /// - Returns: The paths under `path`, or each path when `path` is `nil`.
    static func paths(_ paths: [String], under path: String?) -> [String] {
        guard let path else { return paths }
        return paths.filter { $0 == path || $0.hasPrefix(path + "/") }
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
