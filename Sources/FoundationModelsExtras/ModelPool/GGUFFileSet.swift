import Foundation

/// The files of one GGUF model: the file that llama.cpp loads, every shard of
/// the model, and the image projector beside it.
///
/// ``select(from:under:)`` chooses the files from the file list of a
/// repository or a folder, and the path of a ``ModelRef``, thus a loader that
/// downloads and a loader that reads the disk choose the same files:
/// - A path to a `.gguf` file gives that file. A path to one shard of a split
///   set gives the whole set.
/// - A folder, or the root when the path is `nil`, gives its one model: one
///   GGUF file, or one split set (`*-00001-of-0000N.gguf`) whose first shard
///   is the model. A folder that holds more than one model at any depth fails
///   with ``GGUFSelectionError/ambiguous(path:choices:)``, which lists the
///   choices. The selection never guesses.
/// - An `mmproj*.gguf` file is the image projector: it is not a model and not
///   a shard. The projector is in the folder of the model, or in the nearest
///   folder above it that holds one, up to the root. Of the projectors of one
///   folder, the first by name wins.
public struct GGUFFileSet: Equatable, Sendable {
    /// The extension of a GGUF file.
    public static let fileExtension = "gguf"

    /// The prefix of the name of an image projector file.
    private static let projectorPrefix = "mmproj"

    /// The separator of the segments of a path.
    private static let separator = "/"

    /// The name of a shard of a split set: the stem, the number of the shard,
    /// and the number of shards.
    nonisolated(unsafe) private static let shardName = /^(.+)-(\d{5})-of-(\d{5})\.gguf$/

    /// The number of the first shard of a split set.
    private static let firstShardNumber = 1

    /// The file that llama.cpp loads: the one file of the model, or the first
    /// shard of its split set. A path relative to the root of the list.
    public let model: String

    /// Every file of the model, in the order of the shards. A model of one
    /// file has that file only.
    public let shards: [String]

    /// The image projector of the model, or `nil` when there is none.
    public let projector: String?

    /// Every file to download: the shards, then the projector.
    public var files: [String] {
        shards + (projector.map { [$0] } ?? [])
    }

    /// Makes a file set.
    ///
    /// - Parameters:
    ///   - model: The file that llama.cpp loads.
    ///   - shards: Every file of the model, in the order of the shards.
    ///   - projector: The image projector, or `nil`.
    public init(model: String, shards: [String], projector: String?) {
        self.model = model
        self.shards = shards
        self.projector = projector
    }

    /// Chooses the files of the model that `path` names.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files of the repository or the folder,
    ///     relative to its root.
    ///   - path: The path inside the root: a folder, a `.gguf` file, or `nil`
    ///     for the root.
    /// - Returns: The files of the model.
    /// - Throws: ``GGUFSelectionError`` when the path holds no model, more
    ///   than one model, or a split set with a missing shard.
    public static func select(from paths: [String], under path: String?) throws -> GGUFFileSet {
        let models = paths.filter(isModelFile)
        let candidates: [String]
        if let path, path.hasSuffix(".\(fileExtension)") {
            candidates = models.contains(path) ? [path] : []
        } else {
            let prefix = path.map { $0 + separator } ?? ""
            candidates = models.filter { $0.hasPrefix(prefix) }
        }
        let groups = Dictionary(grouping: candidates, by: modelKey)
        guard !groups.isEmpty else { throw GGUFSelectionError.noModel(path: path) }
        guard groups.count == 1, let (key, _) = groups.first else {
            throw GGUFSelectionError.ambiguous(path: path, choices: groups.keys.map(\.model).sorted())
        }
        let shards = key.shards
        let missing = shards.filter { !models.contains($0) }
        guard missing.isEmpty else { throw GGUFSelectionError.incompleteSplitSet(model: key.model, missing: missing) }
        return GGUFFileSet(model: key.model, shards: shards, projector: projector(for: key.model, in: paths))
    }

    /// Whether `path` is a GGUF file that is not a projector. A shard of a
    /// split set is a model file, whether or not its other shards are listed.
    ///
    /// - Parameter path: A path of the list.
    /// - Returns: `true` for a model file or a shard.
    static func isModelFile(_ path: String) -> Bool {
        URL(filePath: path).pathExtension == fileExtension && !isProjector(path)
    }

    /// Whether `path` is an image projector file.
    ///
    /// - Parameter path: A path of the list.
    /// - Returns: `true` for an `mmproj*.gguf` file.
    private static func isProjector(_ path: String) -> Bool {
        let name = URL(filePath: path).lastPathComponent
        return URL(filePath: path).pathExtension == fileExtension && name.lowercased().hasPrefix(projectorPrefix)
    }

    /// The model that a file belongs to: the file itself, or the split set of
    /// a shard.
    ///
    /// - Parameter path: A model file or a shard.
    /// - Returns: The key of its model.
    private static func modelKey(of path: String) -> ModelKey {
        let folder = (path as NSString).deletingLastPathComponent
        let name = URL(filePath: path).lastPathComponent
        guard let match = name.wholeMatch(of: shardName), let count = Int(match.3), count > 0 else {
            return ModelKey(folder: folder, stem: name, shardCount: nil)
        }
        return ModelKey(folder: folder, stem: String(match.1), shardCount: count)
    }

    /// The projector of `model`: the first by name of the nearest folder that
    /// holds one, from the folder of the model up to the root.
    ///
    /// - Parameters:
    ///   - model: The file that llama.cpp loads.
    ///   - paths: The paths of the list.
    /// - Returns: The projector, or `nil` when no folder holds one.
    private static func projector(for model: String, in paths: [String]) -> String? {
        let projectors = paths.filter(isProjector)
        var folder = (model as NSString).deletingLastPathComponent
        while true {
            let here = projectors.filter { ($0 as NSString).deletingLastPathComponent == folder }.sorted()
            if let first = here.first { return first }
            if folder.isEmpty { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// One model of the list: one file, or one split set.
    private struct ModelKey: Hashable {
        /// The folder of the files, relative to the root, or `""` for the
        /// root.
        let folder: String

        /// The name of the one file, or the stem of the names of the shards.
        let stem: String

        /// The number of shards of a split set, or `nil` for one file.
        let shardCount: Int?

        /// Every file of the model, in the order of the shards.
        var shards: [String] {
            guard let shardCount else { return [path(of: stem)] }
            return (GGUFFileSet.firstShardNumber...shardCount).map { number in
                path(of: String(format: "%@-%05d-of-%05d.%@", stem, number, shardCount, GGUFFileSet.fileExtension))
            }
        }

        /// The file that llama.cpp loads.
        var model: String {
            shards[0]
        }

        /// The path of a file of the folder.
        ///
        /// - Parameter name: The name of the file.
        /// - Returns: The path relative to the root.
        private func path(of name: String) -> String {
            folder.isEmpty ? name : folder + GGUFFileSet.separator + name
        }
    }
}

/// An error of ``GGUFFileSet/select(from:under:)``.
public enum GGUFSelectionError: Error, Equatable, LocalizedError {
    /// The path holds no GGUF model, or names a file that the list does not
    /// hold. `nil` is the root.
    case noModel(path: String?)

    /// The path holds more than one GGUF model. The choices are the file of
    /// each model, which a reference can name as its path.
    case ambiguous(path: String?, choices: [String])

    /// The split set of the model misses shards.
    case incompleteSplitSet(model: String, missing: [String])

    /// A message that tells what is wrong, and how to correct the reference.
    public var errorDescription: String? {
        switch self {
        case .noModel(let path):
            return "\(Self.describe(path)) holds no GGUF model."
        case .ambiguous(let path, let choices):
            return "\(Self.describe(path)) holds more than one GGUF model. "
                + "Add the path of one to the reference: \(choices.joined(separator: ", "))."
        case .incompleteSplitSet(let model, let missing):
            return "The split set of \(model) misses \(missing.joined(separator: ", "))."
        }
    }

    /// The name of a path in a message.
    ///
    /// - Parameter path: The path, or `nil` for the root.
    /// - Returns: The text that names it.
    private static func describe(_ path: String?) -> String {
        path.map { "The path \($0)" } ?? "The root"
    }
}
