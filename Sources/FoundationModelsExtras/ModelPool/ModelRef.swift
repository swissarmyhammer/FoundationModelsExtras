import Foundation

/// A reference to a model on the Hugging Face Hub or on the disk, optionally
/// pinned to a specific revision.
///
/// The string form is `owner/name[/path][@revision]`. A Hub repository id is
/// always exactly two segments, thus each segment after the second `/` is a
/// path inside the repository: a folder, such as a quantization folder of a
/// GGUF repository, or one file. `"unsloth/Qwen3.8-27B-GGUF/Q4_K_M@rev"`
/// parses into the `repo` `"unsloth/Qwen3.8-27B-GGUF"`, the `path`
/// `"Q4_K_M"`, and the `revision` `"rev"`.
///
/// A reference whose text starts with `/`, `~` or `.` is local: its whole
/// text is the `repo`, and it names a folder or a `.gguf` file on the disk.
///
/// `ModelRef` is `ExpressibleByStringLiteral`: a bare string literal such as
/// `"mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"` is a valid `ModelRef`.
///
/// A reference can also name the MTP drafter of the model: a second
/// checkpoint that drafts tokens for the target to verify. A drafter is part
/// of the identity of the reference, because the model it loads speculates.
///
/// The type is a value type with no dependency on MLX. It is `Sendable`,
/// `Hashable`, and `Codable`. A reference with no drafter encodes to and
/// decodes from its canonical string form (`owner/name[/path][@revision]`). A
/// reference with a drafter encodes to a mapping, which a YAML profile writes
/// as:
///
/// ```yaml
/// - repo: mlx-community/Qwen3.8-27B-4bit
///   drafter: mlx-community/Qwen3.8-27B-MTP-4bit
/// ```
public struct ModelRef: Sendable, Hashable, ExpressibleByStringLiteral, Codable {
    /// The Hugging Face repository id, e.g. `"org/repo"`, or the whole
    /// location of a local reference. Never includes the path inside the
    /// repository or the revision suffix.
    public let repo: String

    /// The path inside the repository, e.g. `"Q4_K_M"` or
    /// `"Q4_K_M/model-q4_k_m.gguf"`, or `nil` for the repository root. A local
    /// reference has no path.
    public let path: String?

    /// The pinned revision (commit hash, tag, or branch), or `nil` when the
    /// reference tracks the repository's default revision.
    public let revision: String?

    /// The repository of the MTP drafter, or `nil` for plain decode. Stored
    /// as its parts, because a struct cannot hold a value of its own type.
    private let drafterRepo: String?

    /// The path inside the repository of the MTP drafter.
    private let drafterPath: String?

    /// The pinned revision of the MTP drafter.
    private let drafterRevision: String?

    /// The keys of the mapping form.
    private enum CodingKeys: String, CodingKey {
        case repo, drafter
    }

    /// The separator between repository id and revision in the canonical
    /// string form.
    private static let revisionSeparator: Character = "@"

    /// The separator of the segments of the repository id and of the path.
    private static let segmentSeparator: Character = "/"

    /// The number of segments of a Hub repository id: the owner and the name.
    private static let repositorySegmentCount = 2

    /// The first characters of the text of a local reference: an absolute
    /// path, a path from the home folder, or a path from the current folder.
    private static let localPrefixes: [Character] = ["/", "~", "."]

    /// The extension of a model file that a local reference can name.
    private static let ggufExtension = "gguf"

    /// The revision that a reference with no revision loads. A reference that
    /// names this revision is the same reference as one with no revision.
    /// ``MLXModelLoader`` asks the Hub for this revision.
    static let defaultRevision = "main"

    /// Creates a model reference from an explicit repository id and optional
    /// revision.
    ///
    /// The revision `main` and the empty revision become `nil`, because each
    /// names the default revision. Thus `"org/repo"`, `"org/repo@"` and
    /// `"org/repo@main"` are one reference, with one hash and one
    /// ``stringValue``, and the model pool loads them one time.
    ///
    /// The path `nil`, the empty path and the path `/` all name the
    /// repository root, and a trailing `/` is not part of the path.
    ///
    /// - Parameters:
    ///   - repo: The Hugging Face repository id, e.g. `"org/repo"`, or the
    ///     location of a local reference.
    ///   - path: The path inside the repository, or `nil` for its root.
    ///   - revision: The pinned revision, or `nil` to track the default.
    ///   - drafter: The MTP drafter of the model, or `nil` for plain decode.
    public init(repo: String, path: String? = nil, revision: String? = nil, drafter: ModelRef? = nil) {
        self.repo = repo
        self.path = Self.normalized(path: path)
        self.revision = Self.normalized(revision)
        self.drafterRepo = drafter?.repo
        self.drafterPath = drafter?.path
        self.drafterRevision = drafter?.revision
    }

    /// The MTP drafter of the model, or `nil` for plain decode. The drafter
    /// of a drafter is never kept.
    public var drafter: ModelRef? {
        drafterRepo.map { ModelRef(repo: $0, path: drafterPath, revision: drafterRevision) }
    }

    /// `true` when the reference names a location on the disk, not a
    /// repository on the Hub: its text starts with `/`, `~` or `.`.
    public var isLocal: Bool {
        repo.first.map(Self.localPrefixes.contains) ?? false
    }

    /// Parses a model reference from its string form.
    ///
    /// Splits on the first `@`: text before it is the location and text after
    /// it becomes `revision`. Without an `@`, `revision` is `nil`. The
    /// revision `main` and the empty revision also become `nil`, as in
    /// ``init(repo:path:revision:drafter:)``. The first two segments of the
    /// location of a Hub reference are `repo`, and the rest is `path`. The
    /// whole location of a local reference is `repo`.
    ///
    /// - Parameter string: The reference, e.g. `"org/repo"`,
    ///   `"org/repo/Q4_K_M@rev"` or `"~/models/x.gguf"`.
    public init(_ string: String) {
        let location: Substring
        let revision: String?
        if let separatorIndex = string.firstIndex(of: Self.revisionSeparator) {
            location = string[..<separatorIndex]
            revision = String(string[string.index(after: separatorIndex)...])
        } else {
            location = string[...]
            revision = nil
        }
        guard let first = location.first, !Self.localPrefixes.contains(first) else {
            self.init(repo: String(location), revision: revision)
            return
        }
        let segments = location.split(
            separator: Self.segmentSeparator, maxSplits: Self.repositorySegmentCount,
            omittingEmptySubsequences: false)
        let repo = segments.prefix(Self.repositorySegmentCount).joined(separator: String(Self.segmentSeparator))
        let path = segments.count > Self.repositorySegmentCount ? String(segments[Self.repositorySegmentCount]) : nil
        self.init(repo: repo, path: path, revision: revision)
    }

    /// The folder or the `.gguf` file on the disk that a local reference
    /// names, or `nil` for a reference to the Hub, or for a local reference
    /// whose location is not an existing folder or `.gguf` file. A leading
    /// `~` is the home folder. The loaders of ``ModelPool`` load such a
    /// location with no download and no cache, and they ignore the revision.
    var localLocation: URL? {
        guard isLocal else { return nil }
        let expanded = (repo as NSString).expandingTildeInPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue { return URL(filePath: expanded, directoryHint: .isDirectory) }
        let file = URL(filePath: expanded, directoryHint: .notDirectory)
        return file.pathExtension == Self.ggufExtension ? file : nil
    }

    /// The folder on the disk that a local reference names, or `nil` when the
    /// reference is not local or its location is not a folder.
    var localDirectory: URL? {
        localLocation.flatMap { $0.hasDirectoryPath ? $0 : nil }
    }

    /// Gives `nil` for a path that names the repository root, and drops the
    /// `/` at either end of a path.
    ///
    /// - Parameter path: The path as given.
    /// - Returns: `nil` for `nil`, `""` and `"/"`; otherwise the path with no
    ///   `/` at either end.
    private static func normalized(path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: String(segmentSeparator)))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Gives `nil` for a revision that names the default revision.
    ///
    /// - Parameter revision: The revision as given.
    /// - Returns: `nil` for `nil`, `""` and `"main"`; otherwise `revision`.
    private static func normalized(_ revision: String?) -> String? {
        guard let revision, !revision.isEmpty, revision != defaultRevision else { return nil }
        return revision
    }

    /// Parses a model reference from a string literal, enabling bare literals
    /// such as `let ref: ModelRef = "org/repo@rev"`.
    ///
    /// - Parameter value: The string literal to parse.
    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The canonical string form: `repo`, then `/path` when the reference has
    /// a path, then `@revision` when a revision is set.
    public var stringValue: String {
        let location = path.map { "\(repo)\(Self.segmentSeparator)\($0)" } ?? repo
        guard let revision else { return location }
        return "\(location)\(Self.revisionSeparator)\(revision)"
    }

    /// Encodes the reference as its canonical string form, or as the mapping
    /// `{repo, drafter}` when it names a drafter.
    ///
    /// - Parameter encoder: The encoder to write into.
    /// - Throws: What the encoder throws.
    public func encode(to encoder: Encoder) throws {
        guard let drafter else {
            var container = encoder.singleValueContainer()
            try container.encode(stringValue)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stringValue, forKey: .repo)
        try container.encode(drafter.stringValue, forKey: .drafter)
    }

    /// Decodes a reference from its canonical string form, or from the
    /// mapping `{repo, drafter}`, whose `drafter` is optional. Each value of
    /// the mapping is a string form.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: What the decoder throws.
    public init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            self.init(string)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target = ModelRef(try container.decode(String.self, forKey: .repo))
        let drafter = try container.decodeIfPresent(String.self, forKey: .drafter).map(ModelRef.init(_:))
        self.init(repo: target.repo, path: target.path, revision: target.revision, drafter: drafter)
    }
}
