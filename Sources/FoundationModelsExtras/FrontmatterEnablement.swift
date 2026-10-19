/// Whether a dotfolder document is on, read from the `enabled` key of its
/// frontmatter.
///
/// The rule:
///
/// - When the key is missing, the document is ``enabled``. A frontmatter
///   that is not YAML, or that is not a mapping, holds no key that can be
///   read, thus it also gives ``enabled``.
/// - `enabled: true` gives ``enabled``, and `enabled: false` gives
///   ``disabled``.
/// - Each other value, for example `"false"`, `0` or no value, gives
///   ``invalid(_:)``. An invalid value fails closed: the document is off,
///   because a file that writes the key most likely means to turn the item
///   off.
///
/// `FrontmatterDocumentStack` applies the rule to each document. A consumer
/// with a scan of its own applies it with ``init(frontmatter:)`` or
/// ``init(mapping:)``. The rule holds no lock policy: a consumer decides for
/// itself whether a built-in item can be off.
public enum FrontmatterEnablement: Sendable, Hashable {
  /// The document is on.
  case enabled

  /// The frontmatter says `enabled: false`.
  case disabled

  /// The value of the key is not a bool. The document is off. The value is
  /// the text of the diagnostic.
  case invalid(String)

  /// The frontmatter key that this rule reads.
  public static let key = "enabled"

  /// Whether the document is on. Only ``enabled`` is on.
  public var isEnabled: Bool {
    self == .enabled
  }

  /// Reads the rule from the raw text between the fences of a frontmatter.
  ///
  /// - Parameter frontmatter: The raw frontmatter text, as
  ///   `FrontmatterDocument.split(text:)` gives it.
  public init(frontmatter: String) {
    self.init(mapping: try? YAMLValue.parse(frontmatter))
  }

  /// Reads the rule from a decoded frontmatter.
  ///
  /// - Parameter mapping: The decoded frontmatter, or `nil` when there is
  ///   none or it did not decode.
  public init(mapping: YAMLValue?) {
    guard case .dictionary(let entries)? = mapping, let value = entries[Self.key] else {
      self = .enabled
      return
    }
    guard case .bool(let isOn) = value else {
      self = .invalid("the value of `\(Self.key)` is not true or false, thus the document is off")
      return
    }
    self = isOn ? .enabled : .disabled
  }
}
