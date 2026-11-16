import Foundation
import HuggingFace

/// The download size and the disk state of models, with no download and no
/// model load. A settings pane shows each model, the bytes that its download
/// needs, and the bytes that the cache holds already, before the first
/// download.
///
/// ```swift
/// let storage = ModelStorage()
/// let infos = try await storage.storageInfo(of: ["mlx-community/Qwen3-4B-4bit", "unsloth/Qwen3-8B-GGUF/Q4_K_M"])
/// let downloadBytes = infos.compactMap(\.totalBytes).reduce(0, +)
/// let ready = infos.allSatisfy { $0.state == .complete }
/// ```
///
/// The files of a model are the files that a load of ``HubModelLoader``
/// downloads, in the format that the repository holds:
/// - An MLX repository gives its weights, its configuration and tokenizer
///   files, and its chat templates.
/// - A Core ML repository gives the files of its model package and its
///   tokenizer files, as the load of an embedding model downloads them.
/// - A GGUF repository gives the files that ``GGUFFileSet`` selects under the
///   path of the reference: the model or each shard, and the projector.
/// - A local reference gives each file of its folder, or the GGUF files of
///   its `.gguf` file. It is always ``ModelDiskState/complete``.
///
/// The MTP drafter of a reference is not part of its files. Give the drafter
/// as a reference of its own.
///
/// The sizes come from the tree listing of the revision on the Hub. The
/// storage keeps each listing in the cache, one file for each repository and
/// commit, thus a second call makes no request, and a call with no network
/// uses the kept listing. With no network and no kept listing, the total is
/// `nil`, and the files and the state come from the snapshot in the cache.
///
/// The disk state reads the cache: the links of the snapshot, the blobs, and
/// the `<etag>.incomplete` blobs of interrupted downloads.
public struct ModelStorage: Sendable {
    /// The Hugging Face cache, the token provider and the session of the tree
    /// listings.
    private let hub: HubSource

    /// The kept tree listings, in the cache.
    private let trees: HubTreeMetadataStore

    /// Makes a storage over a Hugging Face cache. Give the same folder and
    /// token provider as the ``HubModelLoader`` of the models.
    ///
    /// - Parameters:
    ///   - cacheDirectory: The folder of the cache. `nil` uses the default
    ///     Hugging Face cache.
    ///   - tokenProvider: The token provider of each tree listing.
    public init(cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment) {
        self.init(
            cache: cacheDirectory.map { HubCache(cacheDirectory: $0) } ?? .default, tokenProvider: tokenProvider,
            session: URLSession(configuration: .default))
    }

    /// Makes a storage over `cache`, whose tree listings go through `session`.
    ///
    /// - Parameters:
    ///   - cache: The Hugging Face cache.
    ///   - tokenProvider: The token provider of each tree listing.
    ///   - session: The URL session of each tree listing.
    init(cache: HubCache, tokenProvider: TokenProvider, session: URLSession) {
        hub = HubSource(cache: cache, tokenProvider: tokenProvider, session: session)
        trees = HubTreeMetadataStore(cache: cache)
    }

    /// Gives the download size and the disk state of each model. The models
    /// are read at the same time.
    ///
    /// - Parameter refs: The models.
    /// - Returns: One information for each model, in the order of `refs`.
    /// - Throws: The first error of ``storageInfo(of:)-(ModelRef)``.
    public func storageInfo(of refs: [ModelRef]) async throws -> [ModelStorageInfo] {
        try await withThrowingTaskGroup(of: (Int, ModelStorageInfo).self) { group in
            for (index, ref) in refs.enumerated() {
                group.addTask { (index, try await storageInfo(of: ref)) }
            }
            let infos = try await group.reduce(into: [Int: ModelStorageInfo]()) { $0[$1.0] = $1.1 }
            return refs.indices.compactMap { infos[$0] }
        }
    }

    /// Gives the download size and the disk state of a model. This makes no
    /// download and loads no model. It makes at most one request: the tree
    /// listing of the revision, when the cache keeps no listing of it.
    ///
    /// - Parameter ref: The model.
    /// - Returns: The information of the model.
    /// - Throws: ``HubModelLoaderError`` for a local location that does not
    ///   exist, or for a path to a model that is not GGUF;
    ///   ``GGUFSelectionError`` when the path holds no GGUF model or more than
    ///   one; ``ModelStorageError``; the error of the tree listing, other than
    ///   a `URLError` of no network; or the error of a file read or of the
    ///   save of the listing.
    public func storageInfo(of ref: ModelRef) async throws -> ModelStorageInfo {
        if ref.isLocal { return try localInfo(of: ref) }
        guard let repo = Repo.ID(rawValue: ref.repo) else {
            throw ModelStorageError.invalidRepository(ref: ref.stringValue)
        }
        let revision = ref.revision ?? ModelRef.defaultRevision
        let commit = commit(of: repo, revision: revision)
        let snapshot = hub.snapshotDirectory(of: ref.repo, revision: revision)
        let metadata = try await treeMetadata(of: repo, revision: commit ?? revision)
        let files: [String]
        if let metadata {
            files = try Self.downloadFiles(of: metadata.paths, ref: ref, allowsMissingShards: false)
        } else {
            files = try Self.cachedFiles(of: snapshot.map(HubSource.relativePaths(in:)) ?? [], ref: ref)
        }
        let etags = metadata?.filesByPath ?? [:]
        let usage = try DiskUsage(
            blobs: files.map { blob(of: $0, etag: etags[$0]?.etag, in: snapshot, repo: repo) })
        let totalBytes = metadata.map { metadata in files.reduce(Int64(0)) { $0 + (etags[$1]?.size ?? 0) } }
        return ModelStorageInfo(
            ref: ref, revision: commit, files: files, totalBytes: totalBytes, presentBytes: usage.presentBytes,
            diskBytes: usage.diskBytes, state: usage.state(fileCount: files.count, totalBytes: totalBytes))
    }

    /// The information of a local reference: each file of its folder, or the
    /// GGUF files of its `.gguf` file. The files are complete, and the total
    /// is their size.
    ///
    /// - Parameter ref: A local reference.
    /// - Returns: The information of the model.
    /// - Throws: ``HubModelLoaderError/missingLocalModel(path:)`` when the
    ///   location does not exist, ``GGUFSelectionError`` for a `.gguf` file
    ///   whose split set misses shards, or the error of a file read.
    private func localInfo(of ref: ModelRef) throws -> ModelStorageInfo {
        guard let location = ref.localLocation else { throw HubModelLoaderError.missingLocalModel(path: ref.repo) }
        let folder = location.hasDirectoryPath ? location : location.deletingLastPathComponent()
        let paths = HubSource.relativePaths(in: folder)
        let files =
            location.hasDirectoryPath
            ? paths.filter { Self.isRegularFile(folder.appending(path: $0)) }.sorted()
            : try GGUFFileSet.select(from: paths, under: location.lastPathComponent).files
        let blobs = files.map { file in
            LocatedBlob(url: folder.appending(path: file).resolvingSymlinksInPath(), isComplete: true)
        }
        let usage = try DiskUsage(blobs: blobs)
        return ModelStorageInfo(
            ref: ref, revision: nil, files: files, totalBytes: usage.presentBytes, presentBytes: usage.presentBytes,
            diskBytes: usage.diskBytes, state: .complete)
    }

    /// The tree listing of a revision: the kept listing, or a new listing of
    /// the Hub, which this keeps.
    ///
    /// - Parameters:
    ///   - repo: The repository.
    ///   - revision: The commit, or the ref when the commit is not known.
    /// - Returns: The listing, or `nil` when the cache keeps none and there is
    ///   no network.
    /// - Throws: The error of the listing other than a `URLError`, or the
    ///   error of the save.
    private func treeMetadata(of repo: Repo.ID, revision: String) async throws -> HubTreeMetadata? {
        if let kept = trees.load(repo: repo, revision: revision) { return kept }
        let metadata: HubTreeMetadata
        do {
            metadata = try await hub.client().treeMetadata(of: repo, revision: revision)
        } catch is URLError {
            return nil
        }
        try trees.save(metadata, repo: repo, revision: revision)
        return metadata
    }

    /// The commit of a revision: the commit that the ref file of the cache
    /// names, or the revision when it is a commit.
    ///
    /// - Parameters:
    ///   - repo: The repository.
    ///   - revision: The ref or the commit.
    /// - Returns: The commit, or `nil` when it is not known.
    private func commit(of repo: Repo.ID, revision: String) -> String? {
        if let resolved = hub.cache.resolveRevision(repo: repo, kind: .model, ref: revision) { return resolved }
        return HubSource.isCommit(revision) ? revision : nil
    }

    /// Finds the blob of a file in the cache: the blob that the snapshot links
    /// to, else the complete blob of its etag, else the `.incomplete` blob of
    /// its etag.
    ///
    /// - Parameters:
    ///   - path: The path of the file in the repository.
    ///   - etag: The etag of the file, or `nil` when it is not known.
    ///   - snapshot: The snapshot folder, or `nil` when the cache holds none.
    ///   - repo: The repository.
    /// - Returns: The blob, or `nil` when the cache holds no byte of the file.
    private func blob(of path: String, etag: String?, in snapshot: URL?, repo: Repo.ID) -> LocatedBlob? {
        if let link = snapshot?.appending(path: path), FileManager.default.fileExists(atPath: link.path) {
            return LocatedBlob(url: link.resolvingSymlinksInPath(), isComplete: true)
        }
        guard let etag else { return nil }
        if let complete = try? hub.cache.completeBlob(repo: repo, etag: etag) {
            return LocatedBlob(url: complete, isComplete: true)
        }
        guard let incomplete = try? hub.cache.incompleteBlob(repo: repo, etag: etag) else { return nil }
        return LocatedBlob(url: incomplete, isComplete: false)
    }

    /// The files that a load downloads, from the paths of a repository, as
    /// ``HubModelLoader`` decides the format.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files of the repository.
    ///   - ref: The model, whose path scopes the files.
    ///   - allowsMissingShards: `true` to give each shard of a GGUF split set
    ///     that misses shards.
    /// - Returns: The paths of the files. MLX and Core ML files are sorted.
    ///   GGUF files are the shards, then the projector.
    /// - Throws: ``HubModelLoaderError/pathNeedsGGUF(ref:)`` for a path to a
    ///   model that is not GGUF, or ``GGUFSelectionError``.
    private static func downloadFiles(of paths: [String], ref: ModelRef, allowsMissingShards: Bool) throws -> [String] {
        let scoped = HubSource.paths(paths, under: ref.path)
        let patterns: [String]
        switch HubModelFormat.detect(paths: scoped) {
        case .gguf:
            return try GGUFFileSet.select(from: paths, under: ref.path, allowsMissingShards: allowsMissingShards).files
        case .mlx: patterns = MLXModelLoader.downloadPatterns
        case .coreML: patterns = CoreMLPackage.downloadPatterns
        }
        guard ref.path == nil else { throw HubModelLoaderError.pathNeedsGGUF(ref: ref.stringValue) }
        return HubSource.paths(scoped, matching: patterns).sorted()
    }

    /// The files that a load downloads, from the paths of the snapshot in the
    /// cache, when no tree listing is available. A GGUF split set that misses
    /// shards gives each shard, thus the missing shards make the state
    /// partial.
    ///
    /// - Parameters:
    ///   - paths: The paths of the snapshot, or none when the cache holds no
    ///     snapshot.
    ///   - ref: The model.
    /// - Returns: The paths of the files, or none when the snapshot holds no
    ///   file under the path of the reference.
    /// - Throws: As ``downloadFiles(of:ref:allowsMissingShards:)``.
    private static func cachedFiles(of paths: [String], ref: ModelRef) throws -> [String] {
        guard !HubSource.paths(paths, under: ref.path).isEmpty else { return [] }
        return try downloadFiles(of: paths, ref: ref, allowsMissingShards: true)
    }

    /// Whether `file` is a regular file, after its symbolic links resolve.
    ///
    /// - Parameter file: The file.
    /// - Returns: `true` for a regular file, `false` for a folder or a file
    ///   that cannot be read.
    private static func isRegularFile(_ file: URL) -> Bool {
        (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

/// The blob of one file of a model in the cache.
private struct LocatedBlob {
    /// The blob on the disk.
    let url: URL

    /// `true` for a complete blob, `false` for the `.incomplete` blob of an
    /// interrupted download.
    let isComplete: Bool
}

/// The bytes of the blobs of the files of a model.
private struct DiskUsage {
    /// The bytes of the blobs, complete and incomplete.
    let presentBytes: Int64

    /// The bytes that the blobs use on the disk. A blob that two files share
    /// counts one time.
    let diskBytes: Int64

    /// The number of files that have a blob.
    let presentCount: Int

    /// The number of files that have a complete blob.
    let completeCount: Int

    /// Measures the blobs of the files of a model.
    ///
    /// - Parameter blobs: The blob of each file, or `nil` for a file that the
    ///   cache does not hold.
    /// - Throws: ``ModelStorageError/unknownFileSize(path:)`` when the file
    ///   system gives no size for a blob, or the error of the read.
    init(blobs: [LocatedBlob?]) throws {
        let present = blobs.compactMap { $0 }
        let sizes = try present.map { try Self.sizes(of: $0.url) }
        let allocated = Dictionary(
            zip(present.map(\.url.path), sizes.map(\.allocated)), uniquingKeysWith: { first, _ in first })
        presentBytes = sizes.reduce(0) { $0 + $1.logical }
        diskBytes = allocated.values.reduce(0, +)
        presentCount = present.count
        completeCount = present.filter(\.isComplete).count
    }

    /// The disk state of a model with these blobs.
    ///
    /// - Parameters:
    ///   - fileCount: The number of files of the model.
    ///   - totalBytes: The sum of the sizes of the files, or `nil`.
    /// - Returns: ``ModelDiskState/missing`` when no file has a blob,
    ///   ``ModelDiskState/complete`` when each file has a complete blob, else
    ///   ``ModelDiskState/partial(presentBytes:totalBytes:)``.
    func state(fileCount: Int, totalBytes: Int64?) -> ModelDiskState {
        guard presentCount > 0 else { return .missing }
        guard completeCount < fileCount else { return .complete }
        return .partial(presentBytes: presentBytes, totalBytes: totalBytes)
    }

    /// The size and the allocated size of a blob.
    ///
    /// - Parameter blob: The blob.
    /// - Returns: The bytes of the blob, and the bytes that it uses on the
    ///   disk.
    /// - Throws: ``ModelStorageError/unknownFileSize(path:)`` when the file
    ///   system gives no size, or the error of the read.
    private static func sizes(of blob: URL) throws -> (logical: Int64, allocated: Int64) {
        let values = try blob.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        guard let size = values.fileSize, let allocated = values.totalFileAllocatedSize else {
            throw ModelStorageError.unknownFileSize(path: blob.path)
        }
        return (Int64(size), Int64(allocated))
    }
}

/// An error of ``ModelStorage``.
public enum ModelStorageError: Error, Equatable, LocalizedError {
    /// The reference is not local, and its repository is not a Hugging Face
    /// repository id (`owner/name`).
    case invalidRepository(ref: String)

    /// The file system gave no size for the blob at `path`.
    case unknownFileSize(path: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let ref):
            return "The model \(ref) does not name a Hugging Face repository as owner/name."
        case .unknownFileSize(let path):
            return "The file system gave no size for the model file \(path)."
        }
    }
}
