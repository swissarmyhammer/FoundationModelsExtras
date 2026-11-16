import Foundation
import HuggingFace

extension HubCache {
    /// Finds the complete blob of a file of a model repository: the blob
    /// that the cache names by the etag of the file.
    ///
    /// - Parameters:
    ///   - repo: The model repository.
    ///   - etag: The etag of the file.
    /// - Returns: The blob, or `nil` when the cache holds no complete blob of
    ///   the etag.
    /// - Throws: `HubCacheError` when the etag is not a safe file name.
    func completeBlob(repo: Repo.ID, etag: String) throws -> URL? {
        Self.existing(try blobPath(repo: repo, kind: .model, etag: etag))
    }

    /// Finds the `.incomplete` blob of a file of a model repository: the
    /// blob that an interrupted download of the etag left behind.
    ///
    /// - Parameters:
    ///   - repo: The model repository.
    ///   - etag: The etag of the file.
    /// - Returns: The `.incomplete` blob, or `nil` when the cache holds none
    ///   for the etag.
    /// - Throws: `HubCacheError` when the etag is not a safe file name.
    func incompleteBlob(repo: Repo.ID, etag: String) throws -> URL? {
        Self.existing(try incompleteBlobPath(repo: repo, kind: .model, etag: etag))
    }

    /// Gives a file when it is on the disk.
    ///
    /// - Parameter file: The file.
    /// - Returns: `file`, or `nil` when the file is not on the disk.
    private static func existing(_ file: URL) -> URL? {
        FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
