import Foundation

/// Where a marketplace comes from, parsed from ``MarketplaceSource/url``
/// (marketplace.md §5.1).
///
/// The forms are:
/// - scp-like SSH: `git@github.com:owner/repo.git`. The parser accepts it, but
///   the transport does not support SSH (marketplace.md decision 10).
/// - HTTPS: `https://github.com/owner/repo.git`
/// - the GitHub shorthand `github:owner/repo`, which expands to
///   `https://github.com/owner/repo.git`
/// - a git repository on this computer: `file:///Users/me/skills.git`
/// - a `#ref` suffix on each git form
/// - a local folder: `file:///Users/me/skills`
///
/// A git form must end in `.git`. Thus a later HTTPS `marketplace.json` form
/// cannot be read as a git repository, and the same suffix tells a `file://`
/// repository from a `file://` folder. The scheme and the host are not case
/// sensitive; the parser writes both in lowercase.
internal enum MarketplaceLocation: Sendable, Hashable {
  /// A git repository.
  ///
  /// `url` is the normalized URL: the shorthand is expanded, the host is in
  /// lowercase, and there is no trailing `/` and no `#ref` suffix. `ref` is
  /// the revision to fetch: the `sha` field, else the `ref` field, else the
  /// `#ref` suffix. It is `nil` for the remote `HEAD`.
  case git(url: String, ref: String?)

  /// A local folder that the store reads directly.
  case local(URL)

  /// The character between a git URL and its ref.
  private static let refSeparator: Character = "#"

  /// The text between a scheme and the rest of a URL.
  private static let schemeSeparator = "://"

  /// The scheme of an HTTPS git URL.
  private static let httpsScheme = "https"

  /// The scheme of a local folder URL.
  private static let fileScheme = "file"

  /// The host name that a `file://` URL can have.
  private static let localHostName = "localhost"

  /// The prefix of the GitHub shorthand, in lowercase.
  private static let githubShorthandPrefix = "github:"

  /// The start of the HTTPS URL that the GitHub shorthand expands to.
  private static let githubRepositoryBase = "https://github.com/"

  /// The number of path components in the GitHub shorthand: the owner and
  /// the repository.
  private static let githubShorthandComponentCount = 2

  /// The suffix of a git repository path.
  private static let gitSuffix = ".git"

  /// The character between the host and the path of an scp-like URL.
  private static let scpPathSeparator: Character = ":"

  /// The character between the user and the host of an scp-like URL.
  private static let userSeparator: Character = "@"

  /// The character between the components of a path.
  private static let pathSeparator: Character = "/"

  /// Parses the location of `source`.
  ///
  /// - Parameter source: The source to parse. Its `sha` field wins over its
  ///   `ref` field, and its `ref` field wins over a `#ref` suffix.
  /// - Throws: ``MarketplaceSourceError`` when the URL is not a §5.1 form,
  ///   or when a local folder has a ref.
  init(source: MarketplaceSource) throws {
    guard !source.url.isEmpty else {
      throw MarketplaceSourceError.emptyURL
    }
    let (address, suffixRef) = try Self.splitRef(source.url)
    let ref = source.sha ?? source.ref ?? suffixRef
    guard ref?.isEmpty != true else {
      throw MarketplaceSourceError.emptyRef
    }
    if Self.namesAFolder(address) {
      guard ref == nil else {
        throw MarketplaceSourceError.refOnLocalFolder
      }
      self = .local(try Self.localFolder(address))
    } else {
      self = .git(url: try Self.gitURL(address), ref: ref)
    }
  }

  /// Whether an address names a local folder and not a git repository.
  ///
  /// A git form ends in `.git`, also over `file://`. Thus
  /// `file:///Users/me/skills` is a folder that the store reads directly,
  /// and `file:///Users/me/skills.git` is a git repository that the
  /// transport fetches.
  ///
  /// - Parameter address: The URL text with no ref.
  /// - Returns: `true` for a `file://` URL that does not end in `.git`.
  private static func namesAFolder(_ address: String) -> Bool {
    guard scheme(of: address) == fileScheme else {
      return false
    }
    return !trimmingTrailingSeparators(address).hasSuffix(gitSuffix)
  }

  /// Removes the trailing `/` characters of a path or a URL.
  ///
  /// The standard library has `trimmingPrefix(while:)` but no suffix twin,
  /// thus the call asks it for the last character that is no separator and
  /// keeps the text up to that character. It makes no reversed copy.
  ///
  /// - Parameter text: The path or the URL.
  /// - Returns: The text with no trailing `/`. A text of separators only
  ///   gives the empty text.
  private static func trimmingTrailingSeparators(_ text: String) -> String {
    guard let end = text.lastIndex(where: { $0 != pathSeparator }) else {
      return ""
    }
    return String(text[...end])
  }

  /// The normalized URL: the git URL with no ref, or `file://` and the
  /// folder path with no trailing `/`.
  var normalizedURL: String {
    switch self {
    case .git(let url, _): url
    case .local(let folder): "\(Self.fileScheme)\(Self.schemeSeparator)\(folder.path)"
    }
  }

  /// The host and the path of a normalized URL.
  ///
  /// ``SourcePattern`` reads these parts, thus the owner rule, the host
  /// regex, and the path prefix all work over the same split that this
  /// parser writes.
  struct NormalizedParts: Sendable, Hashable {
    /// The host, or `nil` for a source on this computer.
    let host: String?

    /// The path. It starts with `/` for every form but the scp-like one.
    let path: String

    /// Whether the source lives on this computer, that is, the URL has
    /// the `file` scheme.
    let isLocal: Bool
  }

  /// Splits a normalized URL into its host and its path.
  ///
  /// A normalized URL has one of three shapes: `file://` and an absolute
  /// path, a scheme with a host and a path, or the scp-like
  /// `[user@]host:path`. The call is a pure function of its input: it reads
  /// no file and opens no connection.
  ///
  /// - Parameter url: The URL that ``normalizedURL`` gave.
  /// - Returns: The host and the path.
  static func parts(ofNormalizedURL url: String) -> NormalizedParts {
    if let separator = url.range(of: schemeSeparator) {
      let rest = url[separator.upperBound...]
      guard url[..<separator.lowerBound] != fileScheme else {
        return NormalizedParts(host: nil, path: String(rest), isLocal: true)
      }
      guard let slash = rest.firstIndex(of: pathSeparator) else {
        return NormalizedParts(host: String(rest), path: "", isLocal: false)
      }
      return NormalizedParts(
        host: String(rest[..<slash]), path: String(rest[slash...]), isLocal: false)
    }
    guard let colon = url.firstIndex(of: scpPathSeparator) else {
      return NormalizedParts(host: nil, path: url, isLocal: false)
    }
    let authority = url[..<colon]
    return NormalizedParts(
      host: String(authority[hostStart(ofAuthority: authority)...]),
      path: String(url[url.index(after: colon)...]), isLocal: false)
  }

  /// The last path component of the repository or of the folder, without
  /// `.git`.
  var repositoryName: String {
    switch self {
    case .git(let url, _): Self.repositoryName(inPath: url)
    case .local(let folder): folder.lastPathComponent
    }
  }

  // MARK: - Parts of a URL

  /// Splits a `#ref` suffix from `text`.
  ///
  /// - Parameter text: The URL text.
  /// - Returns: The text before the first `#`, and the ref after it, or
  ///   `nil` when there is no `#`.
  /// - Throws: ``MarketplaceSourceError/emptyRef`` when the `#` has no text
  ///   after it.
  private static func splitRef(_ text: String) throws -> (address: String, ref: String?) {
    guard let separator = text.firstIndex(of: refSeparator) else {
      return (text, nil)
    }
    let ref = String(text[text.index(after: separator)...])
    guard !ref.isEmpty else {
      throw MarketplaceSourceError.emptyRef
    }
    return (String(text[..<separator]), ref)
  }

  /// Where the host starts inside the authority of an scp-like URL.
  ///
  /// The authority is `[user@]host`. Both ``scpURL(_:)`` and
  /// ``parts(ofNormalizedURL:)`` need the same split, thus the rule lives
  /// here one time.
  ///
  /// - Parameter authority: The text before the `:` of an scp-like URL.
  /// - Returns: The index after the last `@`, else the start of the text.
  private static func hostStart(ofAuthority authority: Substring) -> Substring.Index {
    authority.lastIndex(of: userSeparator).map { authority.index(after: $0) } ?? authority.startIndex
  }

  /// The scheme of `address` in lowercase, or `nil` when it has no `://`.
  ///
  /// - Parameter address: The URL text with no ref.
  /// - Returns: The scheme, or `nil`.
  private static func scheme(of address: String) -> String? {
    address.range(of: schemeSeparator).map { address[..<$0.lowerBound].lowercased() }
  }

  /// The last path component of `path`, without `.git`.
  ///
  /// - Parameter path: A repository path or a full git URL. Both `/` and
  ///   `:` end a component, thus an scp-like URL gives its repository name.
  /// - Returns: The repository name. It is empty when the path has none.
  private static func repositoryName(inPath path: String) -> String {
    let lastComponent = path.split { $0 == pathSeparator || $0 == scpPathSeparator }.last ?? ""
    return String(removingGitSuffix(lastComponent))
  }

  /// Removes one `.git` suffix from `name`.
  ///
  /// - Parameter name: A repository name.
  /// - Returns: The name without the suffix.
  private static func removingGitSuffix(_ name: Substring) -> Substring {
    name.hasSuffix(gitSuffix) ? name.dropLast(gitSuffix.count) : name
  }

  /// Removes the trailing `/` characters of a repository path, and checks
  /// that the path names a repository that ends in `.git`.
  ///
  /// - Parameter path: The path part of a git URL.
  /// - Returns: The path with no trailing `/`.
  /// - Throws: ``MarketplaceSourceError/missingRepository`` or
  ///   ``MarketplaceSourceError/missingGitSuffix``.
  private static func repositoryPath(_ path: String) throws -> String {
    let trimmed = trimmingTrailingSeparators(path)
    guard !repositoryName(inPath: trimmed).isEmpty else {
      throw MarketplaceSourceError.missingRepository
    }
    guard trimmed.hasSuffix(gitSuffix) else {
      throw MarketplaceSourceError.missingGitSuffix
    }
    return trimmed
  }

  // MARK: - Forms

  /// Parses a git form into its normalized URL.
  ///
  /// - Parameter address: The URL text with no ref.
  /// - Returns: The normalized git URL.
  /// - Throws: ``MarketplaceSourceError``.
  private static func gitURL(_ address: String) throws -> String {
    if let scheme = scheme(of: address) {
      switch scheme {
      case httpsScheme:
        return try httpsURL(address)
      case fileScheme:
        return try localRepositoryURL(address)
      default:
        throw MarketplaceSourceError.unsupportedForm
      }
    }
    if address.lowercased().hasPrefix(githubShorthandPrefix) {
      return try githubURL(repository: address.dropFirst(githubShorthandPrefix.count))
    }
    return try scpURL(address)
  }

  /// Parses an HTTPS git URL.
  ///
  /// - Parameter address: The URL text with no ref.
  /// - Returns: The URL with the scheme and the host in lowercase and no
  ///   trailing `/`.
  /// - Throws: ``MarketplaceSourceError``.
  private static func httpsURL(_ address: String) throws -> String {
    guard var components = URLComponents(string: address) else {
      throw MarketplaceSourceError.unsupportedForm
    }
    guard let host = components.host, !host.isEmpty else {
      throw MarketplaceSourceError.missingHost
    }
    guard components.user == nil, components.password == nil else {
      throw MarketplaceSourceError.credentialsInURL
    }
    components.scheme = httpsScheme
    components.host = host.lowercased()
    components.path = try repositoryPath(components.path)
    guard let url = components.string else {
      throw MarketplaceSourceError.unsupportedForm
    }
    return url
  }

  /// Expands the GitHub shorthand.
  ///
  /// - Parameter repository: The text after `github:`, `owner/repo`. A
  ///   `.git` suffix is permitted.
  /// - Returns: `https://github.com/owner/repo.git`.
  /// - Throws: ``MarketplaceSourceError/invalidShorthand``.
  private static func githubURL(repository: Substring) throws -> String {
    let components = repository.split(separator: pathSeparator, omittingEmptySubsequences: false)
    guard components.count == githubShorthandComponentCount,
      let owner = components.first, !owner.isEmpty,
      let name = components.last.map(removingGitSuffix), !name.isEmpty
    else {
      throw MarketplaceSourceError.invalidShorthand
    }
    return "\(githubRepositoryBase)\(owner)\(pathSeparator)\(name)\(gitSuffix)"
  }

  /// Parses an scp-like SSH URL, `[user@]host:path`.
  ///
  /// - Parameter address: The URL text with no ref.
  /// - Returns: The URL with the host in lowercase and no trailing `/`.
  /// - Throws: ``MarketplaceSourceError``.
  private static func scpURL(_ address: String) throws -> String {
    guard let colon = address.firstIndex(of: scpPathSeparator),
      !address[..<colon].contains(pathSeparator)
    else {
      throw MarketplaceSourceError.unsupportedForm
    }
    let authority = address[..<colon]
    let hostStart = hostStart(ofAuthority: authority)
    let host = authority[hostStart...]
    guard !host.isEmpty else {
      throw MarketplaceSourceError.missingHost
    }
    let path = try repositoryPath(String(address[address.index(after: colon)...]))
    return "\(authority[..<hostStart])\(host.lowercased())\(scpPathSeparator)\(path)"
  }

  /// Parses a `file://` URL that names a git repository on this computer.
  ///
  /// libgit2 fetches such a URL over its local transport, thus a test and a
  /// mirror on a disk both work with no network.
  ///
  /// - Parameter address: The URL text with no ref.
  /// - Returns: `file://` and the repository path, with no trailing `/`.
  /// - Throws: ``MarketplaceSourceError/invalidLocalPath`` when the URL has
  ///   a remote host or no absolute path, else
  ///   ``MarketplaceSourceError/missingGitSuffix``.
  private static func localRepositoryURL(_ address: String) throws -> String {
    let folder = try localFolder(address)
    return "\(fileScheme)\(schemeSeparator)\(try repositoryPath(folder.path))"
  }

  /// Parses a `file://` URL into a folder URL.
  ///
  /// - Parameter address: The URL text.
  /// - Returns: The standardized folder URL.
  /// - Throws: ``MarketplaceSourceError/invalidLocalPath`` when the URL has
  ///   a remote host or no absolute path.
  private static func localFolder(_ address: String) throws -> URL {
    guard let url = URL(string: address),
      isLocalHost(url.host),
      url.path.first == pathSeparator
    else {
      throw MarketplaceSourceError.invalidLocalPath
    }
    return URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
  }

  /// Tells whether `host` names this computer: no host, an empty host, or
  /// `localhost`.
  ///
  /// - Parameter host: The host of a `file://` URL.
  /// - Returns: `true` for a local host.
  private static func isLocalHost(_ host: String?) -> Bool {
    guard let host, !host.isEmpty else {
      return true
    }
    return host.lowercased() == localHostName
  }
}
