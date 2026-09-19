import Foundation

/// One rule that names a set of marketplace sources, for the allowlist and
/// the blocklist of ``MarketplacePolicy`` (marketplace.md §6.7).
///
/// A pattern matches the **normalized URL** of a source, never the text that
/// the host wrote. Thus `github:acme/skills` and
/// `https://github.com/acme/skills.git` reach the same pattern, because both
/// normalize to the same HTTPS URL.
///
/// ```swift
/// let policy = MarketplacePolicy(
///   allowedSources: [.owner(host: "github.com", owner: "acme")],
///   blockedSources: [.exact("https://github.com/acme/retired.git")])
/// ```
public enum SourcePattern: Sendable, Hashable, Codable {
  /// One normalized URL, compared letter for letter.
  ///
  /// The parser lowercases the scheme and the host, expands the `github:`
  /// shorthand, and removes a trailing `/` and a `#ref` suffix. Thus the
  /// value here is the URL after that work, for example
  /// `https://github.com/acme/skills.git`.
  case exact(String)

  /// Every repository of one owner on one host.
  ///
  /// The owner is the first path component of the normalized URL, thus the
  /// SSH form `git@github.com:acme/skills.git`, the HTTPS form
  /// `https://github.com/acme/skills.git`, and the shorthand
  /// `github:acme/skills` all match `.owner(host: "github.com", owner:
  /// "acme")`.
  ///
  /// - Parameters:
  ///   - host: The host name. The comparison is not case sensitive.
  ///   - owner: The owner, the organization, or the first folder of the
  ///     repository path. The comparison is case sensitive.
  case owner(host: String, owner: String)

  /// Every host whose whole name matches a regular expression.
  ///
  /// The whole host must match, thus `github` does not match
  /// `github.com` but `.*\.example\.com` matches `git.team.example.com`.
  /// The host of a normalized URL is in lowercase, thus the expression is
  /// written in lowercase. A `file://` source has no host and matches no
  /// expression, and an expression that does not compile matches nothing.
  case hostRegex(String)

  /// Every `file://` source at one path or under it.
  ///
  /// The comparison counts whole path components, thus `/opt/skills`
  /// matches `/opt/skills` and `/opt/skills/team` but not
  /// `/opt/skills-other`. An empty prefix matches every `file://` source. A
  /// remote source has no local path and matches no prefix.
  case pathPrefix(String)

  /// The character between the components of a path.
  private static let pathSeparator: Character = "/"

  /// Whether this pattern names one source.
  ///
  /// The call is a pure function of its input: it reads no file and opens
  /// no connection. Thus the store runs it before any I/O.
  ///
  /// - Parameter normalizedURL: ``MarketplaceLocation/normalizedURL`` of
  ///   the source.
  /// - Returns: `true` when the pattern names the source.
  internal func matches(normalizedURL: String) -> Bool {
    let parts = MarketplaceLocation.parts(ofNormalizedURL: normalizedURL)
    switch self {
    case .exact(let url):
      return normalizedURL == url
    case .owner(let host, let owner):
      return parts.host?.lowercased() == host.lowercased()
        && Self.firstPathComponent(of: parts.path) == owner
    case .hostRegex(let expression):
      return Self.hostMatchesWholly(host: parts.host, expression: expression)
    case .pathPrefix(let prefix):
      return parts.isLocal && Self.isUnderPrefix(path: parts.path, prefix: prefix)
    }
  }

  /// The first path component of a path.
  ///
  /// - Parameter path: The path part of a normalized URL, with or without a
  ///   leading `/`.
  /// - Returns: The first component, or `nil` when the path has none.
  private static func firstPathComponent(of path: String) -> String? {
    components(of: path).first
  }

  /// The non-empty components of a path.
  ///
  /// - Parameter path: The path to split.
  /// - Returns: The components, in order.
  private static func components(of path: String) -> [String] {
    path.split(separator: pathSeparator, omittingEmptySubsequences: true).map(String.init)
  }

  /// Whether the whole host matches a regular expression.
  ///
  /// - Parameters:
  ///   - host: The host of the source, or `nil` for a source on this
  ///     computer.
  ///   - expression: The regular expression of the pattern.
  /// - Returns: `true` when there is a host and the whole host matches. An
  ///   expression that does not compile gives `false`.
  private static func hostMatchesWholly(host: String?, expression: String) -> Bool {
    guard let host, let regex = try? Regex(expression) else {
      return false
    }
    return (try? regex.wholeMatch(in: host)) != nil
  }

  /// Whether one path is a prefix path or lies under it.
  ///
  /// The comparison counts whole components, thus `/opt/skills-other` is
  /// not under `/opt/skills`.
  ///
  /// - Parameters:
  ///   - path: The path of the source.
  ///   - prefix: The prefix of the pattern.
  /// - Returns: `true` when every component of the prefix is the start of
  ///   the path.
  private static func isUnderPrefix(path: String, prefix: String) -> Bool {
    let pathComponents = components(of: path)
    let prefixComponents = components(of: prefix)
    return pathComponents.count >= prefixComponents.count
      && Array(pathComponents.prefix(prefixComponents.count)) == prefixComponents
  }
}

extension SourcePattern: CustomStringConvertible {
  /// One line that names the kind of the pattern and its value, for a
  /// diagnostic, for example `owner "acme" on host "github.com"`.
  public var description: String {
    switch self {
    case .exact(let url):
      #"exact URL "\#(url)""#
    case .owner(let host, let owner):
      #"owner "\#(owner)" on host "\#(host)""#
    case .hostRegex(let expression):
      #"host regex "\#(expression)""#
    case .pathPrefix(let prefix):
      #"path prefix "\#(prefix)""#
    }
  }
}
