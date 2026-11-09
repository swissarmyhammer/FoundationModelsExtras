import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon

/// The files of a GGUF model on the disk: the file that llama.cpp loads,
/// every shard, and the image projector.
public struct GGUFModelFiles: Equatable, Sendable {
    /// The file that llama.cpp loads: the one file of the model, or the first
    /// shard of its split set.
    public let model: URL

    /// Every file of the model, in the order of the shards.
    public let shards: [URL]

    /// The image projector of the model, or `nil`.
    public let projector: URL?

    /// Makes the files of a model.
    ///
    /// - Parameters:
    ///   - model: The file that llama.cpp loads.
    ///   - shards: Every file of the model, in the order of the shards.
    ///   - projector: The image projector, or `nil`.
    public init(model: URL, shards: [URL], projector: URL?) {
        self.model = model
        self.shards = shards
        self.projector = projector
    }

    /// The bytes of the shards and the projector. A file of a snapshot counts
    /// the bytes of the blob that it links to.
    ///
    /// - Returns: The sum of the sizes of the files.
    /// - Throws: ``GGUFSourceError/unknownFileSize(path:)`` when the file
    ///   system gives no size for a file, or the error of the read.
    public func byteCount() throws -> Int64 {
        try (shards + (projector.map { [$0] } ?? [])).reduce(0) { total, file in
            guard let size = try HubSource.blobBytes(of: file) else {
                throw GGUFSourceError.unknownFileSize(path: file.path)
            }
            return total + size
        }
    }
}

/// Finds the files of a GGUF model, and downloads them when the cache does
/// not hold them. A GGUF loader, such as `LlamaCppModelLoader`, gets the
/// files of a ``ModelRef`` here, thus it chooses the same files as
/// ``HubModelLoader`` and reads the same cache.
///
/// ``GGUFFileSet`` chooses the files from the path of the reference:
/// - A local reference reads its folder, or its `.gguf` file and the
///   projector beside it, with no download.
/// - A Hub reference reads the cached snapshot when it holds the model under
///   the path, with no network. Otherwise it lists the files of the
///   repository on the Hub, and downloads only the files of the model and its
///   projector, not the whole repository.
public struct GGUFSource: Sendable {
    /// The Hugging Face cache and the token provider of each download.
    private let hub: HubSource

    /// Makes a source over a Hugging Face cache.
    ///
    /// - Parameters:
    ///   - cacheDirectory: The folder of the cache. `nil` uses the default
    ///     Hugging Face cache.
    ///   - tokenProvider: The token provider of each download.
    public init(cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment) {
        let cache = cacheDirectory.map { HubCache(cacheDirectory: $0) } ?? .default
        hub = HubSource(cache: cache, tokenProvider: tokenProvider)
    }

    /// Gives the files of the model of `ref`, and downloads them first when
    /// the reference is on the Hub and the cache does not hold them.
    ///
    /// - Parameters:
    ///   - ref: The reference of the model.
    ///   - progressHandler: Gets the bytes of the download, then
    ///     ``ModelLoadProgress/loading``. Files on the disk report
    ///     ``ModelLoadProgress/loading`` only.
    /// - Returns: The files of the model.
    /// - Throws: ``GGUFSourceError``, ``GGUFSelectionError``, or the error of
    ///   the file list or the download.
    public func files(
        of ref: ModelRef, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> GGUFModelFiles {
        if let files = try? cachedFiles(of: ref) {
            progressHandler(.loading)
            return files
        }
        if ref.isLocal { return try cachedFiles(of: ref) }
        guard let repo = Repo.ID(rawValue: ref.repo) else { throw GGUFSourceError.notInCache(ref: ref.stringValue) }
        let revision = Self.revision(of: ref)
        let entries = try await hub.client().listFiles(in: repo, kind: .model, revision: revision, recursive: true)
        let set = try GGUFFileSet.select(from: entries.map(\.path), under: ref.path)
        let downloader = ProgressReportingDownloader(upstream: #hubDownloader(hub.client()), report: progressHandler)
        let snapshot = try await downloader.download(
            id: ref.repo, revision: revision, matching: set.files, useLatest: false) { _ in }
        return Self.files(of: set, in: snapshot)
    }

    /// Gives the files of the model of `ref` that are on the disk, with no
    /// network: the local location, or the cached snapshot.
    ///
    /// - Parameter ref: The reference of the model.
    /// - Returns: The files of the model.
    /// - Throws: ``GGUFSourceError/notInCache(ref:)`` when the reference is
    ///   on the Hub and the cache holds no snapshot,
    ///   ``GGUFSourceError/missingLocalModel(path:)`` when a local location
    ///   does not exist, or ``GGUFSelectionError`` when the files hold no
    ///   model, more than one, or not each shard.
    public func cachedFiles(of ref: ModelRef) throws -> GGUFModelFiles {
        if ref.isLocal {
            guard let location = ref.localLocation else { throw GGUFSourceError.missingLocalModel(path: ref.repo) }
            guard location.hasDirectoryPath else {
                let folder = location.deletingLastPathComponent()
                let set = try GGUFFileSet.select(
                    from: HubSource.relativePaths(in: folder), under: location.lastPathComponent)
                return Self.files(of: set, in: folder)
            }
            return Self.files(of: try GGUFFileSet.select(from: HubSource.relativePaths(in: location), under: nil), in: location)
        }
        guard let snapshot = hub.snapshotDirectory(of: ref.repo, revision: Self.revision(of: ref)) else {
            throw GGUFSourceError.notInCache(ref: ref.stringValue)
        }
        let set = try GGUFFileSet.select(from: HubSource.relativePaths(in: snapshot), under: ref.path)
        return Self.files(of: set, in: snapshot)
    }

    /// The files of `set` in `folder`.
    ///
    /// - Parameters:
    ///   - set: The chosen files, relative to `folder`.
    ///   - folder: The folder or the snapshot that holds them.
    /// - Returns: The files as URLs.
    private static func files(of set: GGUFFileSet, in folder: URL) -> GGUFModelFiles {
        let url = { (path: String) in folder.appending(path: path, directoryHint: .notDirectory) }
        return GGUFModelFiles(model: url(set.model), shards: set.shards.map(url), projector: set.projector.map(url))
    }

    /// The revision of `ref` that the source reads.
    ///
    /// - Parameter ref: The reference of the model.
    /// - Returns: The pinned revision, or `main`.
    private static func revision(of ref: ModelRef) -> String {
        ref.revision ?? ModelRef.defaultRevision
    }
}

/// An error of ``GGUFSource``.
public enum GGUFSourceError: Error, Equatable, LocalizedError {
    /// The reference is on the Hub, and the cache holds no snapshot of it.
    case notInCache(ref: String)

    /// The reference is local, and its location is not an existing folder or
    /// `.gguf` file.
    case missingLocalModel(path: String)

    /// The file system gave no size for the file at `path`.
    case unknownFileSize(path: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .notInCache(let ref):
            return "The Hugging Face cache does not hold the GGUF model \(ref)."
        case .missingLocalModel(let path):
            return "The model \(path) is not a folder or a .gguf file on the disk."
        case .unknownFileSize(let path):
            return "The file system gave no size for the GGUF file \(path)."
        }
    }
}
