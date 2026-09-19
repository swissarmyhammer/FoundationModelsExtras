import Foundation
import Marketplace

/// A ``GitTransport`` that counts the calls of the store, records the
/// credential that each fetch received, and then does the real libgit2 work.
///
/// A pure double would put no object in the bare repository, thus the store
/// would have no tree to read. The recorder wraps ``LibGit2Transport``
/// instead, so a store test sees real snapshots and still counts the calls.
/// It is public so that the store tests of `FoundationModelsSkills` inject
/// it.
public actor RecordingGitTransport: GitTransport {
  /// The transport that does the work.
  private let base = LibGit2Transport()

  /// How many times the store asked for a remote head.
  public private(set) var remoteHeadCount = 0

  /// How many times the store fetched.
  public private(set) var fetchCount = 0

  /// The credential that the provider of each fetch gave, in call order.
  /// An entry is `nil` when the fetch got no provider.
  public private(set) var fetchCredentials: [MarketplaceCredential?] = []

  /// Makes a recorder with no call yet.
  public init() {}

  public func remoteHead(
    url: String, ref: String, credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
  ) async throws -> String {
    remoteHeadCount += 1
    return try await base.remoteHead(url: url, ref: ref, credentials: credentials)
  }

  public func fetch(
    url: String, revision: String, intoBareRepository repositoryURL: URL,
    credentials: (@Sendable (URL) async -> MarketplaceCredential?)?
  ) async throws -> String {
    fetchCount += 1
    fetchCredentials.append(await Self.credential(from: credentials, forURL: url))
    return try await base.fetch(
      url: url, revision: revision, intoBareRepository: repositoryURL, credentials: credentials)
  }

  /// Asks a credentials provider for the credential of one source.
  ///
  /// - Parameters:
  ///   - credentials: The provider of the call, or `nil` when the call got
  ///     none.
  ///   - url: The git URL of the remote.
  /// - Returns: The credential, or `nil` when there is no provider or the
  ///   provider gives none.
  private static func credential(
    from credentials: (@Sendable (URL) async -> MarketplaceCredential?)?, forURL url: String
  ) async -> MarketplaceCredential? {
    guard let credentials, let requestURL = URL(string: url) else {
      return nil
    }
    return await credentials(requestURL)
  }
}
