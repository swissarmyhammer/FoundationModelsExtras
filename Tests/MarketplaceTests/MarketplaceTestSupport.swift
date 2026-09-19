import Foundation
import Marketplace

/// Records each URL that a credential provider gets.
///
/// `CredentialGateTests` and `GitTransportTests` both prove that a credential
/// provider is asked one time, and with which URL. Thus the recorder is here,
/// and not in one of the two suites.
actor CredentialRequestRecorder {
  /// The URL of each request, in order.
  private(set) var requestedURLs: [URL] = []

  /// Records one request.
  ///
  /// - Parameter url: The URL that the provider got.
  func record(url: URL) {
    requestedURLs.append(url)
  }

  /// Makes a provider that records each request and gives `credential`.
  ///
  /// - Parameter credential: The credential that the provider gives.
  /// - Returns: The provider.
  nonisolated func provider(giving credential: MarketplaceCredential) -> @Sendable (URL) async -> MarketplaceCredential? {
    { url in
      await self.record(url: url)
      return credential
    }
  }
}
