import Foundation
import FoundationModelsExtras
import HuggingFace
import MLX
import Testing

/// The memory measures of the memory checks.
///
/// A check compares a change of ``activeBytes`` with the weights of one model,
/// as ``weightBytes(of:)`` gives them.
enum ModelMemory {
    /// The file extension of a weight file.
    private static let weightFileExtension = "safetensors"

    /// The revision that `MLXModelLoader` loads for a model reference that
    /// names no revision.
    private static let defaultRevision = "main"

    /// The bytes of the MLX arrays that are alive now, in the process.
    ///
    /// This is the active memory counter of MLX. It does not count the buffer
    /// cache of MLX: MLX keeps a freed buffer there for a later array, and the
    /// buffer then has no model data.
    static var activeBytes: Int { Memory.activeMemory }

    /// The bytes of the weight files of `key` in the Hugging Face cache, at the
    /// revision that `MLXModelLoader` loads.
    ///
    /// A loaded model keeps each tensor of these files as one MLX array, thus
    /// this is about the active memory that one load adds. This measure reads
    /// the cache without `MLXModelLoader`, thus a test can compare it with the
    /// footprint that the loader measures.
    ///
    /// - Parameter key: One of the models of ``IntegrationModels``.
    /// - Returns: The sum of the sizes of the weight files.
    /// - Throws: A failed expectation when the cache does not hold the model,
    ///   or the error of a file read.
    static func weightBytes(of key: ModelPoolKey) throws -> Int {
        let repo = try #require(Repo.ID(rawValue: key.ref.repo))
        let revision = key.ref.revision ?? defaultRevision
        let commit = try #require(
            HubCache.default.resolveRevision(repo: repo, kind: .model, ref: revision),
            "The Hugging Face cache holds no \(revision) revision of \(key.ref.stringValue).")
        let snapshot = try HubCache.default.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        let files = try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == weightFileExtension }.reduce(0) { total, file in
            // The snapshot holds a link to each blob. The size is the size of the blob.
            let size = try file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize
            return total + (try #require(size))
        }
    }
}
