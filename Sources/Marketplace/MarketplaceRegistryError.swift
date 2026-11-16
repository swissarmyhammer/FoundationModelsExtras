import Foundation

/// Why a ``MarketplaceRegistry`` cannot do an operation.
///
/// No message holds a URL or a credential: it names only an id, or the
/// problem of the source.
public enum MarketplaceRegistryError: Error, Equatable, Sendable {
  /// Another marketplace of the list has the id already.
  ///
  /// - Parameter id: The id that more than one marketplace would have.
  case duplicateMarketplace(id: String)

  /// No marketplace of the list has the id.
  ///
  /// - Parameter id: The id that the host gave.
  case unknownMarketplace(id: String)

  /// The source gives no id: its URL is bad, or its pre-fetch key is not one
  /// folder name.
  ///
  /// - Parameter error: The error of the parser of the source.
  case invalidSource(MarketplaceSourceError)
}

extension MarketplaceRegistryError: LocalizedError {
  /// A sentence that tells the problem and, when possible, the correction.
  public var errorDescription: String? {
    switch self {
    case .duplicateMarketplace(let id):
      #"A marketplace with the id "\#(id)" is in the list already. Set a different alias on the source."#
    case .unknownMarketplace(let id):
      #"No marketplace has the id "\#(id)"."#
    case .invalidSource(let error):
      "The marketplace source is not usable: \(error)"
    }
  }
}
