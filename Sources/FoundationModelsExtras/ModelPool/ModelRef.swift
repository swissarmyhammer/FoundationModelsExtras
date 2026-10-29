/// A reference to a model on the Hugging Face Hub, optionally pinned to a
/// specific revision.
///
/// A `ModelRef` names a repository (e.g. `"mlx-community/Qwen2.5-Coder-32B"`)
/// and, when revision-pinned, a particular commit, tag, or branch within it.
/// The pinned form uses an `@` separator: `"org/repo@rev"` parses into the
/// `repo` `"org/repo"` and the `revision` `"rev"`. Without an `@`, the whole
/// string is the `repo` and `revision` is `nil`.
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
/// decodes from its canonical string form (`repo` or `repo@revision`). A
/// reference with a drafter encodes to a mapping, which a YAML profile writes
/// as:
///
/// ```yaml
/// - repo: mlx-community/Qwen3.8-27B-4bit
///   drafter: mlx-community/Qwen3.8-27B-MTP-4bit
/// ```
public struct ModelRef: Sendable, Hashable, ExpressibleByStringLiteral, Codable {
    /// The Hugging Face repository id, e.g. `"org/repo"`. Never includes the
    /// revision suffix.
    public let repo: String

    /// The pinned revision (commit hash, tag, or branch), or `nil` when the
    /// reference tracks the repository's default revision.
    public let revision: String?

    /// The repository of the MTP drafter, or `nil` for plain decode. Stored
    /// as its parts, because a struct cannot hold a value of its own type.
    private let drafterRepo: String?

    /// The pinned revision of the MTP drafter.
    private let drafterRevision: String?

    /// The keys of the mapping form.
    private enum CodingKeys: String, CodingKey {
        case repo, drafter
    }

    /// The separator between repository id and revision in the canonical
    /// string form.
    private static let revisionSeparator: Character = "@"

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
    /// - Parameters:
    ///   - repo: The Hugging Face repository id, e.g. `"org/repo"`.
    ///   - revision: The pinned revision, or `nil` to track the default.
    ///   - drafter: The MTP drafter of the model, or `nil` for plain decode.
    public init(repo: String, revision: String? = nil, drafter: ModelRef? = nil) {
        self.repo = repo
        self.revision = Self.normalized(revision)
        self.drafterRepo = drafter?.repo
        self.drafterRevision = drafter?.revision
    }

    /// The MTP drafter of the model, or `nil` for plain decode. The drafter
    /// of a drafter is never kept.
    public var drafter: ModelRef? {
        drafterRepo.map { ModelRef(repo: $0, revision: drafterRevision) }
    }

    /// Parses a model reference from its string form.
    ///
    /// Splits on the first `@`: text before it becomes `repo` and text after it
    /// becomes `revision`. Without an `@`, the whole string is `repo` and
    /// `revision` is `nil`. The revision `main` and the empty revision also
    /// become `nil`, as in ``init(repo:revision:)``.
    ///
    /// - Parameter string: The reference, e.g. `"org/repo"` or `"org/repo@rev"`.
    public init(_ string: String) {
        if let separatorIndex = string.firstIndex(of: Self.revisionSeparator) {
            self.init(
                repo: String(string[..<separatorIndex]),
                revision: String(string[string.index(after: separatorIndex)...]))
        } else {
            self.init(repo: string)
        }
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

    /// The canonical string form: `repo` when unpinned, or `repo@revision` when
    /// a revision is set.
    public var stringValue: String {
        guard let revision else { return repo }
        return "\(repo)\(Self.revisionSeparator)\(revision)"
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
        self.init(repo: target.repo, revision: target.revision, drafter: drafter)
    }
}
