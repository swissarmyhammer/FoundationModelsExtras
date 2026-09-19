/// A user name and a token for a private HTTPS marketplace (marketplace.md
/// §5.1).
///
/// The host gives a credential through a `credentials` provider. The git
/// transport asks the provider only for an HTTPS source, and it sends the
/// credential only to the origin of that source, one time for each git call.
///
/// The text of a credential shows neither the user name nor the token. Thus a
/// log line, a diagnostic, or an error message that prints a credential shows
/// no secret.
///
/// ```swift
/// let credentials: @Sendable (URL) async -> MarketplaceCredential? = { url in
///   url.host == "git.example.com" ? MarketplaceCredential(username: "reader", token: token) : nil
/// }
/// ```
public struct MarketplaceCredential: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  /// The text that stands for a credential in every description.
  private static let redactedText = "MarketplaceCredential(<redacted>)"

  /// The user name. Some hosts accept any user name with a token.
  public let username: String

  /// The token or password.
  public let token: String

  /// Creates a credential.
  ///
  /// - Parameters:
  ///   - username: The user name.
  ///   - token: The token or password.
  public init(username: String, token: String) {
    self.username = username
    self.token = token
  }

  /// A text that shows no secret: `MarketplaceCredential(<redacted>)`.
  public var description: String {
    Self.redactedText
  }

  /// A text that shows no secret, the same as ``description``.
  public var debugDescription: String {
    Self.redactedText
  }

  /// A mirror with no children, thus `dump(_:)` and a reflection show no
  /// secret.
  public var customMirror: Mirror {
    Mirror(self, children: [], displayStyle: .struct)
  }
}
