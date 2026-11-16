import Foundation
import HuggingFace

/// The file list of one revision of a repository on the Hub, with the size and
/// the etag of each file. ``ModelStorage`` keeps one copy for each repository
/// and revision on the disk, thus a second call and a call with no network
/// need no request.
struct HubTreeMetadata: Codable, Equatable, Sendable {
    /// One file of the revision.
    struct File: Codable, Equatable, Sendable {
        /// The path of the file, relative to the root of the repository.
        let path: String

        /// The size of the file in bytes, or `nil` when the Hub gives none.
        let size: Int64?

        /// The etag of the file, which names its blob in the cache: the Git
        /// LFS object id of an LFS file, else the Git object id. `nil` when
        /// the Hub gives neither.
        let etag: String?
    }

    /// The files of the revision. A folder of the tree is not a file.
    let files: [File]

    /// Makes the metadata from a tree listing of the Hub.
    ///
    /// - Parameter entries: The entries of the listing.
    init(entries: [Git.TreeEntry]) {
        files = entries.filter { $0.type == .file }.map { entry in
            File(path: entry.path, size: entry.effectiveSize.map(Int64.init), etag: entry.lfs?.oid ?? entry.oid)
        }
    }

    /// The paths of the files.
    var paths: [String] {
        files.map(\.path)
    }

    /// The files by path.
    var filesByPath: [String: File] {
        Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The folder of the cached ``HubTreeMetadata`` files in a Hugging Face cache.
/// Each file is `trees/<revision>.json` in the metadata folder of the
/// repository, beside the metadata of swift-huggingface, whose names it does
/// not use.
struct HubTreeMetadataStore: Sendable {
    /// The name of the folder of the files in the metadata folder of a
    /// repository.
    private static let folderName = "trees"

    /// The extension of a metadata file.
    private static let fileExtension = "json"

    /// The characters of a revision that stay as they are in a file name. Each
    /// other character, such as the `/` of `refs/pr/5` or a `.`, is
    /// percent-encoded, thus no revision names a folder above the file.
    private static let fileNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    /// The cache that holds the metadata folder.
    let cache: HubCache

    /// Reads the cached metadata of a revision.
    ///
    /// A file that cannot be read or decoded is the same as no file: the
    /// caller asks the Hub again, and the save writes a new file over it.
    ///
    /// - Parameters:
    ///   - repo: The repository.
    ///   - revision: The commit, or the ref when the commit is not known.
    /// - Returns: The metadata, or `nil` when the cache holds none.
    func load(repo: Repo.ID, revision: String) -> HubTreeMetadata? {
        guard let url = url(repo: repo, revision: revision), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HubTreeMetadata.self, from: data)
    }

    /// Writes the metadata of a revision to the cache. A revision whose name
    /// gives no file name is not saved.
    ///
    /// - Parameters:
    ///   - metadata: The metadata.
    ///   - repo: The repository.
    ///   - revision: The commit, or the ref when the commit is not known.
    /// - Throws: The error of the encode, of the folder creation or of the
    ///   write.
    func save(_ metadata: HubTreeMetadata, repo: Repo.ID, revision: String) throws {
        guard let url = url(repo: repo, revision: revision) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
    }

    /// The file of the metadata of a revision.
    ///
    /// - Parameters:
    ///   - repo: The repository.
    ///   - revision: The commit or the ref.
    /// - Returns: The file, or `nil` when the revision cannot be encoded as a
    ///   file name.
    private func url(repo: Repo.ID, revision: String) -> URL? {
        guard let name = revision.addingPercentEncoding(withAllowedCharacters: Self.fileNameCharacters) else {
            return nil
        }
        return cache.metadataDirectory(repo: repo, kind: .model)
            .appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension(Self.fileExtension)
    }
}
