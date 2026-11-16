import Foundation

/// The disk state of the files of a model: all of the files that a load
/// downloads, some of them, or none.
public enum ModelDiskState: Sendable, Codable, Hashable {
    /// The cache, or the local folder, holds each file of the model. A load
    /// downloads nothing.
    case complete

    /// The cache holds some of the bytes of the model: complete files, or the
    /// blob of an interrupted download.
    ///
    /// - Parameters:
    ///   - presentBytes: The bytes of the model that the cache holds.
    ///   - totalBytes: The bytes of each file of the model, or `nil` when the
    ///     metadata of the Hub is not available.
    case partial(presentBytes: Int64, totalBytes: Int64?)

    /// The cache holds no byte of the model.
    case missing
}

/// The download size and the disk state of one model, which
/// ``ModelStorage/storageInfo(of:)-(ModelRef)`` gives with no download and no
/// model load.
public struct ModelStorageInfo: Sendable, Codable, Equatable {
    /// The model.
    public let ref: ModelRef

    /// The commit of the revision of the model, when it is known: the commit
    /// that the ref file of the cache names, or the revision of the reference
    /// when it is a commit. `nil` for a local reference, or when the cache
    /// does not name the commit.
    public let revision: String?

    /// The paths of the files that a load of the model downloads, relative to
    /// the root of the repository, or to the folder of a local reference.
    public let files: [String]

    /// The sum of the sizes of ``files``, from the metadata of the Hub, or
    /// `nil` when the metadata is not available. For example, a call with no
    /// network and no cached metadata has no total.
    public let totalBytes: Int64?

    /// The bytes of ``files`` that the cache holds: the complete blobs, and
    /// the `.incomplete` blobs of interrupted downloads.
    public let presentBytes: Int64

    /// The bytes that the blobs of ``files`` use on the disk. A blob that two
    /// files share counts one time.
    public let diskBytes: Int64

    /// The disk state of the model.
    public let state: ModelDiskState

    /// Makes the storage information of a model.
    ///
    /// - Parameters:
    ///   - ref: The model.
    ///   - revision: The commit of the revision, or `nil` when it is not known.
    ///   - files: The paths of the files that a load downloads.
    ///   - totalBytes: The sum of the sizes of the files, or `nil` when it is
    ///     not known.
    ///   - presentBytes: The bytes of the files that the cache holds.
    ///   - diskBytes: The bytes that the blobs of the files use on the disk.
    ///   - state: The disk state of the model.
    public init(
        ref: ModelRef, revision: String?, files: [String], totalBytes: Int64?, presentBytes: Int64, diskBytes: Int64,
        state: ModelDiskState
    ) {
        self.ref = ref
        self.revision = revision
        self.files = files
        self.totalBytes = totalBytes
        self.presentBytes = presentBytes
        self.diskBytes = diskBytes
        self.state = state
    }
}
