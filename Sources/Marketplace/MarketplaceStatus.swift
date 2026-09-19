/// What a check of one marketplace found (marketplace.md §8.1).
///
/// A check is a cheap remote query: it reads the commit that the remote head
/// names and compares it with the snapshot on the disk. It downloads no skill
/// content.
///
/// No field holds a URL or a credential, thus a row that a host shows holds
/// no secret.
public struct MarketplaceStatus: Sendable, Hashable {
  /// The display id of the marketplace.
  public var id: String

  /// The commit that `current` names, or `nil` when the marketplace has no
  /// snapshot yet.
  public var current: String?

  /// The commit that the remote head names, or `nil` when the check
  /// failed.
  public var latest: String?

  /// Why the check failed, or `nil` when it worked. The text never holds a
  /// credential.
  public var error: String?

  /// Whether the remote holds a commit that the snapshot does not.
  public var updateAvailable: Bool {
    guard let latest else {
      return false
    }
    return latest != current
  }

  /// Creates a status.
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - current: The commit that `current` names, or `nil` for a
  ///     marketplace with no snapshot. The default is `nil`.
  ///   - latest: The commit that the remote head names, or `nil` for a
  ///     check that failed. The default is `nil`.
  ///   - error: Why the check failed, or `nil` when it worked. The default
  ///     is `nil`.
  public init(id: String, current: String? = nil, latest: String? = nil, error: String? = nil) {
    self.id = id
    self.current = current
    self.latest = latest
    self.error = error
  }
}
