import Foundation
import HuggingFace

/// The lookups of a blob of a model repository by its etag.
///
/// An etag that is not a safe file name, for example an etag that holds `..`
/// or `/`, has no blob in the cache. Each lookup then gives `nil`, the same
/// result as for a blob that is not on the disk. Thus a caller treats such a
/// file as a file with no cached blob: the download of the file goes to the
/// upstream download, which does its own check of the etag.
extension HubCache {
    /// Finds the complete blob of a file of a model repository: the blob
    /// that the cache names by the etag of the file.
    ///
    /// - Parameters:
    ///   - repo: The model repository.
    ///   - etag: The etag of the file.
    /// - Returns: The blob, or `nil` when the cache holds no complete blob of
    ///   the etag or the etag is not a safe file name.
    func completeBlob(repo: Repo.ID, etag: String) -> URL? {
        Self.existing(try? blobPath(repo: repo, kind: .model, etag: etag))
    }

    /// Finds the `.incomplete` blob of a file of a model repository: the
    /// blob that an interrupted download of the etag left behind.
    ///
    /// - Parameters:
    ///   - repo: The model repository.
    ///   - etag: The etag of the file.
    /// - Returns: The `.incomplete` blob, or `nil` when the cache holds none
    ///   for the etag or the etag is not a safe file name.
    func incompleteBlob(repo: Repo.ID, etag: String) -> URL? {
        Self.existing(try? incompleteBlobPath(repo: repo, kind: .model, etag: etag))
    }

    /// Gives a file when it is on the disk.
    ///
    /// - Parameter file: The file, or `nil` when the etag gave no path.
    /// - Returns: `file`, or `nil` when there is no file or the file is not
    ///   on the disk.
    private static func existing(_ file: URL?) -> URL? {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
