import FixtureSupport
import Foundation
import HuggingFace
import Testing

@testable import FoundationModelsExtras

/// A temporary Hugging Face cache with one repository, and the writes that
/// put files of the repository in it as a download does.
struct HubFixture {
    /// The temporary folder of the cache.
    let root: URL

    /// The cache.
    let cache: HubCache

    /// The repository of the files.
    let repo: Repo.ID

    /// The commit of the snapshot that the `main` ref names.
    let commit: String

    /// Makes an empty cache in a new temporary folder.
    ///
    /// - Parameters:
    ///   - repository: The repository of the files.
    ///   - commit: The commit of the snapshot.
    /// - Throws: The error of the folder creation, or an issue when the
    ///   repository is not a valid id.
    init(repository: String, commit: String) throws {
        root = try TemporaryDirectory.make()
        cache = HubCache(cacheDirectory: root)
        repo = try #require(Repo.ID(rawValue: repository))
        self.commit = commit
    }

    /// Removes the temporary folder.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A storage over the cache, whose requests go to `stub`.
    ///
    /// - Parameter stub: The transport of the hub client.
    /// - Returns: The storage.
    func storage(_ stub: HubStub) -> ModelStorage {
        ModelStorage(cache: cache, tokenProvider: .none, session: stub.session)
    }

    /// Writes each file as a complete download writes it: a blob named by
    /// its etag, a link in the snapshot, and the `main` ref.
    ///
    /// - Parameter files: The files.
    /// - Throws: The error of a file write.
    func writeComplete(_ files: [HubStub.TreeFile]) throws {
        try cache.updateRef(repo: repo, kind: .model, ref: ModelRef.defaultRevision, commit: commit)
        let snapshot = try cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        for file in files {
            let blob = try cache.blobPath(repo: repo, kind: .model, etag: file.etag)
            try Self.writeBytes(file.size, to: blob)
            let link = snapshot.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        }
    }

    /// Writes the `.incomplete` blob of an interrupted download of a file.
    ///
    /// - Parameters:
    ///   - file: The file.
    ///   - bytes: The bytes that the download wrote.
    /// - Throws: The error of the file write.
    func writeIncomplete(_ file: HubStub.TreeFile, bytes: Int) throws {
        try Self.writeBytes(bytes, to: try cache.incompleteBlobPath(repo: repo, kind: .model, etag: file.etag))
    }

    /// The bytes that the blobs of the files use on the disk.
    ///
    /// - Parameter files: Files that ``writeComplete(_:)`` wrote.
    /// - Returns: The sum of the allocated sizes of their blobs.
    /// - Throws: The error of the read of a size.
    func allocatedBytes(of files: [HubStub.TreeFile]) throws -> Int64 {
        try files.reduce(0) { total, file in
            let blob = try cache.blobPath(repo: repo, kind: .model, etag: file.etag)
            let values = try blob.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return total + Int64(try #require(values.totalFileAllocatedSize))
        }
    }

    /// Writes each file in a folder, with the size of the file.
    ///
    /// - Parameters:
    ///   - files: The files.
    ///   - folder: The folder.
    /// - Throws: The error of a file write.
    static func write(_ files: [HubStub.TreeFile], in folder: URL) throws {
        for file in files {
            try writeBytes(file.size, to: folder.appendingPathComponent(file.path))
        }
    }

    /// Writes a file of `count` bytes, and makes its folder.
    ///
    /// - Parameters:
    ///   - count: The number of bytes.
    ///   - file: The file.
    /// - Throws: The error of the write.
    private static func writeBytes(_ count: Int, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: count).write(to: file)
    }
}
