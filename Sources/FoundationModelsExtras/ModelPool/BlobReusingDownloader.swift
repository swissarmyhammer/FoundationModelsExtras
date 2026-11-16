import Foundation
import HuggingFace
import MLXLMCommon

/// A downloader that gives the files of a revision their cached blobs before
/// an upstream Hugging Face download.
///
/// The blobs of the Hugging Face cache have the hash of the file as their
/// name: the SHA-256 of an LFS file, else the Git object id. A new commit of a
/// repository often keeps most files, thus most hashes. The upstream download
/// finds a cached blob only through the `HEAD` request of each file, and when
/// that request fails or gives no etag, it downloads the whole file again.
///
/// This downloader asks the Hub for the commit of the revision and for the
/// tree listing of that commit. For each file of the download whose blob the
/// cache holds, it makes the link in the snapshot of the commit. The upstream
/// download of the commit then finds each such file in the cache and sends no
/// request for it. A file with a new hash downloads as before. After the
/// download, the ref file of a revision that is not a commit names the commit.
///
/// When the Hub does not give the commit or the listing, for example with no
/// network, the upstream download runs for the revision as is. It then uses
/// the cached snapshot of the revision, as it does with no network.
struct BlobReusingDownloader: Downloader {
    /// The commit and the files of one revision.
    private struct RevisionTree {
        /// The commit of the revision.
        let commit: String

        /// The files of the commit, with the etag of each.
        let metadata: HubTreeMetadata
    }

    /// The client that asks the Hub for the commit and the listing.
    private let client: HubClient

    /// The cache of the blobs and the snapshots. The upstream download writes
    /// to the same cache.
    private let cache: HubCache

    /// The downloader that downloads the files.
    private let upstream: any Downloader

    /// Makes a downloader over `upstream`.
    ///
    /// - Parameters:
    ///   - client: The client that asks the Hub for the commit and the
    ///     listing.
    ///   - cache: The cache that the upstream download writes to.
    ///   - upstream: The downloader that downloads the files.
    init(client: HubClient, cache: HubCache, upstream: any Downloader) {
        self.client = client
        self.cache = cache
        self.upstream = upstream
    }

    /// Links each cached blob of the revision, then downloads the files of
    /// `patterns` with the upstream downloader.
    ///
    /// - Parameters:
    ///   - id: The repository.
    ///   - revision: The revision, or `nil` for `main`.
    ///   - patterns: The patterns of the files to download.
    ///   - useLatest: Given to the upstream downloader.
    ///   - progressHandler: Gets each progress of the upstream download.
    /// - Returns: The snapshot folder of the commit of the revision.
    /// - Throws: The error of a link, of the upstream download, or of the
    ///   write of the ref file.
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let revision = revision ?? ModelRef.defaultRevision
        guard let repo = Repo.ID(rawValue: id), let tree = try await tree(of: repo, revision: revision) else {
            return try await upstream.download(
                id: id, revision: revision, matching: patterns, useLatest: useLatest, progressHandler: progressHandler)
        }
        try await linkCachedBlobs(of: tree, repo: repo, matching: patterns)
        let snapshot = try await upstream.download(
            id: id, revision: tree.commit, matching: patterns, useLatest: useLatest, progressHandler: progressHandler)
        if revision != tree.commit {
            try cache.updateRef(repo: repo, kind: .model, ref: revision, commit: tree.commit)
        }
        return snapshot
    }

    /// Asks the Hub for the commit of a revision and for the tree listing of
    /// that commit. The listing is of the commit, not of the revision, thus a
    /// revision that moves between the two requests cannot mix two commits.
    ///
    /// - Parameters:
    ///   - repo: The repository.
    ///   - revision: The ref or the commit.
    /// - Returns: The commit and its files, or `nil` when a request fails or
    ///   the Hub gives no commit.
    /// - Throws: `CancellationError` when the task is cancelled.
    private func tree(of repo: Repo.ID, revision: String) async throws -> RevisionTree? {
        do {
            let commit = HubSource.isCommit(revision) ? revision : try await client.getModel(repo, revision: revision).sha
            guard let commit else { return nil }
            let entries = try await client.listFiles(in: repo, kind: .model, revision: commit, recursive: true)
            return RevisionTree(commit: commit, metadata: HubTreeMetadata(entries: entries))
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// Links each file of `patterns` in the snapshot of the commit to its
    /// blob, when the cache holds the blob and the snapshot has no link for
    /// the file.
    ///
    /// - Parameters:
    ///   - tree: The commit and its files.
    ///   - repo: The repository.
    ///   - patterns: The patterns of the files of the download.
    /// - Throws: `HubCacheError` for an etag or a path that is not safe, or
    ///   the error of a link.
    private func linkCachedBlobs(of tree: RevisionTree, repo: Repo.ID, matching patterns: [String]) async throws {
        let files = tree.metadata.filesByPath
        for path in HubSource.paths(tree.metadata.paths, matching: patterns) {
            guard let etag = files[path]?.etag,
                cache.cachedFilePath(repo: repo, kind: .model, revision: tree.commit, filename: path) == nil
            else { continue }
            let blob = try cache.blobPath(repo: repo, kind: .model, etag: etag)
            guard FileManager.default.fileExists(atPath: blob.path) else { continue }
            try await cache.storeFile(
                at: blob, repo: repo, kind: .model, revision: tree.commit, filename: path, etag: etag)
        }
    }
}
