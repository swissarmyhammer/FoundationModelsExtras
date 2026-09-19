/// Why a ``MarketplaceSource`` gives no location or no pre-fetch key
/// (marketplace.md §5.1 and §5.3).
internal enum MarketplaceSourceError: Error, Equatable, Sendable {
  /// The URL is empty.
  case emptyURL

  /// The URL is not one of the §5.1 forms.
  case unsupportedForm

  /// The URL has no host.
  case missingHost

  /// The URL has no repository name.
  case missingRepository

  /// The repository path of a git form does not end in `.git`.
  case missingGitSuffix

  /// The HTTPS URL has a user name or a password in it.
  case credentialsInURL

  /// The GitHub shorthand is not `github:owner/repo`.
  case invalidShorthand

  /// The ref is empty: a `#` with no text after it, or an empty `ref` or
  /// `sha` field.
  case emptyRef

  /// The `file://` URL has a remote host, or no absolute path.
  case invalidLocalPath

  /// A local folder has a `#ref` suffix, a `ref` field, or a `sha` field.
  case refOnLocalFolder

  /// The pre-fetch key is not one folder name: it is empty, or it has a
  /// `/` or a NUL character in it.
  case unusableKey(String)
}

extension MarketplaceSourceError: CustomStringConvertible {
  /// A sentence that tells the problem and, when possible, the correction.
  var description: String {
    switch self {
    case .emptyURL:
      "The URL is empty."
    case .unsupportedForm:
      "The URL is not a supported form. Use https://host/owner/repo.git, github:owner/repo, or file:///path."
    case .missingHost:
      "The URL has no host."
    case .missingRepository:
      "The URL has no repository name."
    case .missingGitSuffix:
      #"The repository path does not end in ".git"."#
    case .credentialsInURL:
      "The HTTPS URL has a user name or a password in it. Do not put credentials in the URL."
    case .invalidShorthand:
      "The GitHub shorthand must be github:owner/repo."
    case .emptyRef:
      "The ref is empty."
    case .invalidLocalPath:
      "The file URL must have an absolute path and no remote host."
    case .refOnLocalFolder:
      "A local folder has no ref and no sha. Remove the #ref suffix, the ref field, and the sha field."
    case .unusableKey(let key):
      #"The pre-fetch key "\#(key)" is not one folder name. Set an alias that is not empty and that has no "/"."#
    }
  }
}
