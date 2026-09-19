/// Why a store cannot pin or unpin a marketplace (marketplace.md §8.3).
///
/// No message holds a URL or a credential: it names only the id that the host
/// gave.
public enum MarketplacePinError: Error, Equatable, Sendable {
  /// No source of the store has that pre-fetch key and no source has that
  /// display id.
  ///
  /// - Parameter id: The id that the host gave.
  case unknownMarketplace(id: String)

  /// The marketplace is a folder on this computer. The folder is the layer
  /// itself, thus it has no commit to pin (marketplace.md §5.1).
  ///
  /// - Parameter id: The id of the marketplace.
  case notAGitMarketplace(id: String)
}

extension MarketplacePinError: CustomStringConvertible {
  /// A sentence that names the marketplace and what the store cannot do.
  public var description: String {
    switch self {
    case .unknownMarketplace(let id):
      #"No marketplace has the id "\#(id)"."#
    case .notAGitMarketplace(let id):
      #"""
      The marketplace "\#(id)" is a folder on this computer, thus it has no commit to pin.
      """#
    }
  }
}
