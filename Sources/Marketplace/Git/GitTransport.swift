import Foundation

/// The git operations that the marketplace store needs (marketplace.md §5.1,
/// decision 10).
///
/// The package never starts the `git` binary. ``LibGit2Transport`` does this
/// work with libgit2. The protocol is public: the store gets a
/// `GitTransport` value, and a store test in another package gives a counting
/// double instead (marketplace.md §13), which `@testable import` cannot do
/// across a package boundary. A change of the libgit2 package changes only
/// the concrete type.
///
/// No implementation has a built-in timeout. A call stops when its task is
/// cancelled, and it then throws ``GitTransportError/cancelled``.
///
/// Each call takes an optional `credentials` provider for a private HTTPS
/// source. An implementation asks it at most one time, before the git work
/// starts, and only for an HTTPS URL: an SSH URL and a `file://` URL never ask.
/// The credential goes only to a request with the scheme, the host, and the
/// port of the source URL, and only one time (``CredentialGate``).
public protocol GitTransport: Sendable {
  /// Reads the commit that `ref` names on the remote, with no download of
  /// content (the `ls-remote` equivalent).
  ///
  /// - Parameters:
  ///   - url: The git URL of the remote.
  ///   - ref: A branch name, a tag name, or `HEAD`. A branch wins over a tag
  ///     with the same name. An annotated tag gives the commit that it peels
  ///     to.
  ///   - credentials: Gives the credential for an HTTPS source, or `nil`
  ///     for no credential.
  /// - Returns: The 40-hex SHA of the commit.
  /// - Throws: ``GitTransportError``.
  func remoteHead(
    url: String, ref: String, credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
  ) async throws -> String

  /// Fetches one commit into a bare repository, as a shallow fetch.
  ///
  /// - Parameters:
  ///   - url: The git URL of the remote.
  ///   - revision: A 40-hex SHA, or a ref name in the form that
  ///     ``remoteHead(url:ref:credentials:)`` takes.
  ///   - repositoryURL: The directory of the bare repository. The call makes
  ///     the repository when it does not exist.
  ///   - credentials: Gives the credential for an HTTPS source, or `nil`
  ///     for no credential.
  /// - Returns: The 40-hex SHA of the fetched commit.
  /// - Throws: ``GitTransportError``.
  func fetch(
    url: String, revision: String, intoBareRepository repositoryURL: URL,
    credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
  ) async throws -> String
}

/// Why a libgit2 call of the marketplace failed: a ``GitTransport`` call, or a
/// read of a fetched commit through ``GitTreeFileSource``.
///
/// No case carries a credential. A refused credential is
/// ``GitTransportError/unreachable(message:)`` with a fixed message, never
/// with text from libgit2.
public enum GitTransportError: Error, Equatable, Sendable {
  /// The remote cannot be reached: the host, the network, the
  /// authentication, the path, or the URL protocol failed before the remote
  /// listed its refs. A credential that the remote refused, or no credential
  /// where the remote asks for one, is also this case.
  ///
  /// `message` says why. For a libgit2 failure it is the libgit2 message,
  /// thus a host that is down and a transport that the libgit2 build does
  /// not have give different text (for example `unsupported URL protocol`).
  case unreachable(message: String)

  /// The remote has no ref or object with the requested name.
  case refNotFound

  /// The task of the call was cancelled, and the call stopped.
  case cancelled

  /// The network or the server stopped the operation with a timeout. The
  /// transport has no timeout of its own.
  case timedOut

  /// Another libgit2 failure, with its code and message.
  case libgit2(code: Int32, message: String)
}
