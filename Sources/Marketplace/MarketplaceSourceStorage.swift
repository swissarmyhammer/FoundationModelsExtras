/// The place where a host keeps its list of marketplace sources.
///
/// ``MarketplaceRegistry`` reads the list from the storage before each
/// operation, and it saves the full list after each change. Thus the storage
/// is the one copy of the list. A host gives its own storage, for example a
/// layer of its user settings.
public protocol MarketplaceSourceStorage: Sendable {
  /// Reads the stored list.
  ///
  /// - Returns: The sources, in list order.
  /// - Throws: The error of the storage when it cannot read the list.
  func loadSources() async throws -> [MarketplaceSource]

  /// Replaces the stored list.
  ///
  /// - Parameter sources: The full new list, in list order.
  /// - Throws: The error of the storage when it cannot save the list. The
  ///   stored list then stays as it was.
  func saveSources(_ sources: [MarketplaceSource]) async throws
}

/// A ``MarketplaceSourceStorage`` that holds the list in memory.
///
/// Use it in tests, and in a host that does not keep the list after it
/// stops.
public actor InMemoryMarketplaceSourceStorage: MarketplaceSourceStorage {
  /// The stored list, in list order.
  private var sources: [MarketplaceSource]

  /// Makes a storage that holds `sources`.
  ///
  /// - Parameter sources: The list at the start. The default is an empty
  ///   list.
  public init(sources: [MarketplaceSource] = []) {
    self.sources = sources
  }

  /// Gives the stored list.
  ///
  /// - Returns: The sources, in list order.
  public func loadSources() -> [MarketplaceSource] {
    sources
  }

  /// Replaces the stored list.
  ///
  /// - Parameter sources: The full new list, in list order.
  public func saveSources(_ sources: [MarketplaceSource]) {
    self.sources = sources
  }
}
