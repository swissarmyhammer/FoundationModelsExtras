/// One finding about a marketplace source, its catalog, or its sync
/// (marketplace.md §6.2).
///
/// A diagnostic does not stop the other marketplaces. The ``severity`` tells
/// what the store did about the finding.
public struct MarketplaceDiagnostic: Sendable, Hashable {
  /// How serious a diagnostic is, from the least serious to the most
  /// serious.
  public enum Severity: String, Sendable, Hashable, CaseIterable {
    /// A note. The store changes nothing, for example for a renamed
    /// skill.
    case advisory

    /// The store does not use a part of a marketplace, for example a
    /// selected name that is not in the catalog.
    case warning

    /// The store does not use a marketplace or the source list, for
    /// example when two sources have the same pre-fetch key.
    case error
  }

  /// How serious this diagnostic is.
  public var severity: Severity

  /// The marketplace that the diagnostic is about: its pre-fetch key or its
  /// display id. It is `nil` when the diagnostic is not about one
  /// marketplace.
  public var marketplaceID: String?

  /// The text of the diagnostic.
  public var message: String

  /// Creates a diagnostic.
  ///
  /// - Parameters:
  ///   - severity: How serious the diagnostic is.
  ///   - marketplaceID: The marketplace that the diagnostic is about, or
  ///     `nil`.
  ///   - message: The text of the diagnostic.
  public init(severity: Severity, marketplaceID: String?, message: String) {
    self.severity = severity
    self.marketplaceID = marketplaceID
    self.message = message
  }
}

extension MarketplaceDiagnostic: CustomStringConvertible {
  /// One line with the severity, the marketplace id when there is one, and
  /// the message, for example `"[error] skills: The key is used two times."`.
  public var description: String {
    let subject = marketplaceID.map { "\($0): " } ?? ""
    return "[\(severity.rawValue)] \(subject)\(message)"
  }
}
