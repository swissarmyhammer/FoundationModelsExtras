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
/// cache holds, it makes the link in the snapshot of the commit. It downloads
/// each other file with a ``ResumableFileDownload``, which retries a stalled
/// transfer from the bytes that it wrote, and then makes the link of the
/// file. The upstream download of the commit then finds each file in the
/// cache and sends no request for it. After the download, the ref file of a
/// revision that is not a commit names the commit.
///
/// The upstream download cannot continue a stalled transfer: it writes each
/// file to a temporary file of the URL session, and a cancel removes that
/// file. Thus the files of the tree download here, and only a file that the
/// tree gives no safe etag for downloads upstream.
///
/// When the Hub does not give the commit or the listing, for example with no
/// network, the upstream download runs for the revision as is. It then uses
/// the cached snapshot of the revision, as it does with no network.
///
/// In the offline mode, the downloader sends no request: it does not ask for
/// the tree, it downloads no file, and it does not call the upstream download.
/// The upstream download sends a request for each revision that is not a
/// commit with saved snapshot metadata, also when the cache holds the
/// snapshot. The downloader gives the cached snapshot of the revision, whose
/// commit the ref file names.
struct BlobReusingDownloader: Downloader {
    /// The failure of a model information request that gives no commit.
    private enum RevisionTreeError: Error {
        /// The Hub gave the model information with no commit.
        case noCommit
    }

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

    /// One file of the tree that the snapshot of the commit does not hold,
    /// and whose blob the cache does not hold.
    private struct MissingFile: Sendable {
        /// The path of the file in the repository.
        let path: String

        /// The size of the file in bytes, or `nil` when the Hub gives none.
        let size: Int64?

        /// The etag of the file.
        let etag: String

        /// The blob of the file.
        let blob: URL

        /// The `.incomplete` blob of the file.
        let incompleteBlob: URL
    }

    /// The most files that download at the same time.
    static let maximumConcurrentDownloads = 8

    /// The downloader of each file that the cache does not hold.
    private let files: ResumableFileDownload

    /// The downloader of the snapshot after the files of the tree are in the
    /// cache, and of each file whose etag is not safe.
    private let upstream: any Downloader

    /// `true` when the downloader sends no request and gives only the cached
    /// snapshot.
    private let offline: Bool

    /// Makes a downloader over `upstream`.
    ///
    /// - Parameters:
    ///   - client: The client that asks the Hub for the commit and the
    ///     listing.
    ///   - cache: The cache that the downloads write to.
    ///   - files: The downloader of each file that the cache does not hold.
    ///   - upstream: The downloader of the snapshot.
    ///   - offline: `true` when the downloader sends no request and gives
    ///     only the cached snapshot.
    init(
        client: HubClient, cache: HubCache, files: ResumableFileDownload, upstream: any Downloader,
        offline: Bool = false
    ) {
        self.client = client
        self.cache = cache
        self.files = files
        self.upstream = upstream
        self.offline = offline
    }

    /// Links each cached blob of the revision, downloads each other file of
    /// `patterns`, then gives the snapshot with the upstream downloader. In
    /// the offline mode, gives the cached snapshot of the revision with no
    /// request.
    ///
    /// - Parameters:
    ///   - id: The repository.
    ///   - revision: The revision, or `nil` for `main`.
    ///   - patterns: The patterns of the files to download.
    ///   - useLatest: Given to the upstream downloader.
    ///   - progressHandler: Gets the byte progress of the files, then each
    ///     progress of the upstream download.
    /// - Returns: The snapshot folder of the commit of the revision.
    /// - Throws: The error of a link, of a file download, of the upstream
    ///   download, or of the write of the ref file. In the offline mode,
    ///   ``ModelDownloadError/notCachedOffline(repository:revision:)`` when
    ///   the cache holds no snapshot of the revision.
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let revision = revision ?? ModelRef.defaultRevision
        if offline { return try HubSource.offlineSnapshotDirectory(in: cache, of: id, revision: revision) }
        guard let repo = Repo.ID(rawValue: id), let tree = try await tree(of: repo, revision: revision) else {
            return try await upstream.download(
                id: id, revision: revision, matching: patterns, useLatest: useLatest, progressHandler: progressHandler)
        }
        try await linkCachedBlobs(of: tree, repo: repo, matching: patterns)
        try await downloadMissingFiles(of: tree, repo: repo, matching: patterns, progressHandler: progressHandler)
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
    /// Each failure other than cancellation gives `nil`, and the download
    /// then runs upstream for the revision as is. The catch is broad on
    /// purpose. A `URLError` occurs with no network. An HTTP error, for
    /// example a 401 or a 404, occurs for a repository that only the cache
    /// holds, such as a local repository of a test. A decoding error occurs
    /// for an answer of a mirror that is not complete. In each case the
    /// upstream download falls back to the cached snapshot of the revision,
    /// as it does when its own listing fails. A debug record keeps the type
    /// of each such error.
    ///
    /// - Parameters:
    ///   - repo: The repository.
    ///   - revision: The ref or the commit.
    /// - Returns: The commit and its files, or `nil` when a request fails or
    ///   the Hub gives no commit.
    /// - Throws: `CancellationError` when the task is cancelled.
    private func tree(of repo: Repo.ID, revision: String) async throws -> RevisionTree? {
        do {
            let commit = try await commit(of: repo, revision: revision)
            return RevisionTree(commit: commit, metadata: try await client.treeMetadata(of: repo, revision: commit))
        } catch {
            try Task.checkCancellation()
            PoolTelemetry.logRevisionTreeUnavailable(error, of: repo.rawValue)
            return nil
        }
    }

    /// The commit of a revision: the revision when it is a commit, else the
    /// commit that the Hub gives for it.
    ///
    /// - Parameters:
    ///   - repo: The repository.
    ///   - revision: The ref or the commit.
    /// - Returns: The commit.
    /// - Throws: The error of the model information request, or
    ///   ``RevisionTreeError/noCommit`` when the Hub gives no commit.
    private func commit(of repo: Repo.ID, revision: String) async throws -> String {
        if HubSource.isCommit(revision) { return revision }
        guard let commit = try await client.getModel(repo, revision: revision).sha else {
            throw RevisionTreeError.noCommit
        }
        return commit
    }

    /// Links each file of `patterns` in the snapshot of the commit to its
    /// blob, when the cache holds the blob and the snapshot has no link for
    /// the file. A file whose etag is not a safe file name has no cached
    /// blob, thus it gets no link, and the upstream download handles it.
    ///
    /// - Parameters:
    ///   - tree: The commit and its files.
    ///   - repo: The repository.
    ///   - patterns: The patterns of the files of the download.
    /// - Throws: `HubCacheError` for a path that is not safe, or the error of
    ///   a link.
    private func linkCachedBlobs(of tree: RevisionTree, repo: Repo.ID, matching patterns: [String]) async throws {
        let files = tree.metadata.filesByPath
        for path in HubSource.paths(tree.metadata.paths, matching: patterns) {
            guard let etag = files[path]?.etag,
                cache.cachedFilePath(repo: repo, kind: .model, revision: tree.commit, filename: path) == nil
            else { continue }
            guard let blob = cache.completeBlob(repo: repo, etag: etag) else { continue }
            try await cache.storeFile(
                at: blob, repo: repo, kind: .model, revision: tree.commit, filename: path, etag: etag)
        }
    }

    /// Downloads each file of `patterns` that the snapshot of the commit does
    /// not hold, and links it in the snapshot. At most
    /// ``maximumConcurrentDownloads`` files download at the same time. The
    /// progress handler gets the bytes of the files on the disk after each
    /// write.
    ///
    /// - Parameters:
    ///   - tree: The commit and its files.
    ///   - repo: The repository.
    ///   - patterns: The patterns of the files of the download.
    ///   - progressHandler: Gets the byte progress of the files.
    /// - Throws: The error of the read of the size of an `.incomplete` blob,
    ///   of a file download, or of a link.
    private func downloadMissingFiles(
        of tree: RevisionTree, repo: Repo.ID, matching patterns: [String],
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws {
        let filesByPath = tree.metadata.filesByPath
        let matched = HubSource.paths(tree.metadata.paths, matching: patterns).compactMap { filesByPath[$0] }
        let missing = matched.compactMap { missingFile($0, repo: repo, commit: tree.commit) }
        guard !missing.isEmpty else { return }
        let present = matched.filter {
            cache.cachedFilePath(repo: repo, kind: .model, revision: tree.commit, filename: $0.path) != nil
        }
        let progress = try Self.byteProgress(present: present, missing: missing, progressHandler: progressHandler)
        progress.report()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = missing.makeIterator()
            for _ in 0..<Self.maximumConcurrentDownloads {
                guard let file = pending.next() else { break }
                group.addTask { try await downloadFile(file, of: repo, at: tree.commit, progress: progress) }
            }
            while try await group.next() != nil {
                guard let file = pending.next() else { continue }
                group.addTask { try await downloadFile(file, of: repo, at: tree.commit, progress: progress) }
            }
        }
    }

    /// The file of the tree when the snapshot of the commit does not hold
    /// it, the cache holds no blob of it, and its etag is a safe file name.
    ///
    /// - Parameters:
    ///   - file: A file of the tree.
    ///   - repo: The repository.
    ///   - commit: The commit of the snapshot.
    /// - Returns: The file to download, or `nil` when the cache holds it or
    ///   the upstream download handles it.
    private func missingFile(_ file: HubTreeMetadata.File, repo: Repo.ID, commit: String) -> MissingFile? {
        guard let etag = file.etag,
            cache.cachedFilePath(repo: repo, kind: .model, revision: commit, filename: file.path) == nil,
            cache.completeBlob(repo: repo, etag: etag) == nil,
            let blob = try? cache.blobPath(repo: repo, kind: .model, etag: etag),
            let incompleteBlob = try? cache.incompleteBlobPath(repo: repo, kind: .model, etag: etag)
        else { return nil }
        return MissingFile(path: file.path, size: file.size, etag: etag, blob: blob, incompleteBlob: incompleteBlob)
    }

    /// Downloads one missing file into its blob, and links it in the snapshot
    /// of the commit. The download holds the lock of the blob that the
    /// upstream download and the cache also take, thus two downloads never
    /// write the same blob. When the blob exists after the lock, another
    /// download wrote it, and only the link is made.
    ///
    /// - Parameters:
    ///   - file: The file.
    ///   - repo: The repository.
    ///   - commit: The commit of the snapshot.
    ///   - progress: Gets the bytes of the file on the disk.
    /// - Throws: The error of the download, of the move of the blob, or of
    ///   the link.
    private func downloadFile(
        _ file: MissingFile, of repo: Repo.ID, at commit: String, progress: SnapshotByteProgress
    ) async throws {
        try FileManager.default.createDirectory(
            at: file.blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FileLock(path: cache.lockPath(for: file.blob), maxRetries: nil).withLock {
            guard !FileManager.default.fileExists(atPath: file.blob.path) else { return }
            try await files.download(file.path, of: repo, at: commit, into: file.incompleteBlob) { bytes in
                progress.record(bytes, of: file.path)
            }
            try FileManager.default.moveItem(at: file.incompleteBlob, to: file.blob)
        }
        progress.record(try HubSource.blobBytes(of: file.blob) ?? 0, of: file.path)
        try await cache.storeFile(
            at: file.blob, repo: repo, kind: .model, revision: commit, filename: file.path, etag: file.etag)
    }

    /// The byte progress of the files that download here and of the files
    /// that the snapshot holds. Each file of the snapshot counts its size,
    /// and each missing file counts the bytes of its `.incomplete` blob. A
    /// file that the upstream download handles does not count.
    ///
    /// - Parameters:
    ///   - present: The files of the patterns that the snapshot holds.
    ///   - missing: The files that download here.
    ///   - progressHandler: Gets each report.
    /// - Returns: The progress.
    /// - Throws: The error of the read of the size of an `.incomplete` blob.
    private static func byteProgress(
        present: [HubTreeMetadata.File], missing: [MissingFile],
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) throws -> SnapshotByteProgress {
        let presentBytes = present.map { ($0.path, $0.size ?? 0) }
        let missingBytes = try missing.map { ($0.path, try HubSource.bytesOnDisk(of: $0.incompleteBlob)) }
        let totalBytes = presentBytes.map(\.1).reduce(0, +) + missing.compactMap(\.size).reduce(0, +)
        return SnapshotByteProgress(
            totalBytes: totalBytes,
            bytesByPath: Dictionary(presentBytes + missingBytes, uniquingKeysWith: { first, _ in first }),
            progressHandler: progressHandler)
    }
}
