/// One marketplace of a ``MarketplaceRegistry``: a source and its id.
public struct MarketplaceEntry: Sendable, Hashable, Identifiable {
  /// The pre-fetch key of the source: its alias, else the repository name.
  ///
  /// It is the same display id that ``MarketplaceStore`` gives the
  /// marketplace.
  public let id: String

  /// The source of the marketplace.
  public let source: MarketplaceSource

  /// Makes the entry of `source`.
  ///
  /// - Parameter source: The source.
  /// - Throws: ``MarketplaceRegistryError/invalidSource(_:)`` when the URL of
  ///   the source is bad, or when its pre-fetch key is not usable.
  init(source: MarketplaceSource) throws {
    do {
      id = try MarketplaceIdentity.preFetchKey(for: source)
    } catch let error as MarketplaceSourceError {
      throw MarketplaceRegistryError.invalidSource(error)
    }
    self.source = source
  }
}
