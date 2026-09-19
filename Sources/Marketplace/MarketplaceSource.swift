/// One marketplace that a host names (marketplace.md §5.1 and §6.2).
///
/// A source is a pure value. It does no I/O. The store parses ``url`` into a
/// location, and it derives the pre-fetch key from ``alias`` or from the
/// repository name.
///
/// ```swift
/// let sources = [
///   MarketplaceSource("https://github.com/swissarmyhammer/skills.git"),
///   MarketplaceSource("github:acme/team-skills", autoUpdate: false),
/// ]
/// ```
public struct MarketplaceSource: Sendable, Hashable, Codable {
  /// The location of the marketplace, in a §5.1 form: an HTTPS URL that
  /// ends in `.git`, `github:owner/repo`, or a `file://` URL. A git form can
  /// have a `#ref` suffix. The parser also accepts an scp-like SSH URL, but
  /// the transport does not support SSH, thus such a source never connects.
  public var url: String

  /// A branch or a tag. It wins over a `#ref` suffix on ``url``.
  public var ref: String?

  /// A commit pin. It wins over ``ref``, and it stops automatic update.
  public var sha: String?

  /// A subfolder of the repository. The store reads only that path.
  public var path: String?

  /// A local name for the marketplace. When it is set, it is the pre-fetch
  /// key.
  public var alias: String?

  /// The skills that the host takes from the catalog.
  public var select: SkillSelection

  /// Whether the store installs a new commit when it finds one.
  public var autoUpdate: Bool

  /// Creates a source.
  ///
  /// - Parameters:
  ///   - url: The location, in a §5.1 form.
  ///   - ref: A branch or a tag. It wins over a `#ref` suffix on `url`.
  ///   - sha: A commit pin. It wins over `ref`.
  ///   - path: A subfolder of the repository.
  ///   - alias: A local name. It is the pre-fetch key when it is set.
  ///   - select: The skills to take. The default is `.all`.
  ///   - autoUpdate: Whether the store installs a new commit when it finds
  ///     one. The default is `true`.
  public init(
    _ url: String,
    ref: String? = nil,
    sha: String? = nil,
    path: String? = nil,
    alias: String? = nil,
    select: SkillSelection = .all,
    autoUpdate: Bool = true
  ) {
    self.url = url
    self.ref = ref
    self.sha = sha
    self.path = path
    self.alias = alias
    self.select = select
    self.autoUpdate = autoUpdate
  }

  /// Whether the source is pinned to one commit, that is, it has a ``sha``.
  public var isPinned: Bool {
    sha != nil
  }

  /// Decodes a source. Only `url` is necessary. A field that is not in the
  /// input gets the default of ``init(_:ref:sha:path:alias:select:autoUpdate:)``,
  /// and a key that names no field at all is ignored.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when `url` is not there, or when a field has
  ///   the wrong type.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      try container.decode(String.self, forKey: .url),
      ref: try container.decodeIfPresent(String.self, forKey: .ref),
      sha: try container.decodeIfPresent(String.self, forKey: .sha),
      path: try container.decodeIfPresent(String.self, forKey: .path),
      alias: try container.decodeIfPresent(String.self, forKey: .alias))
    if let select = try container.decodeIfPresent(SkillSelection.self, forKey: .select) {
      self.select = select
    }
    if let autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) {
      self.autoUpdate = autoUpdate
    }
  }
}
