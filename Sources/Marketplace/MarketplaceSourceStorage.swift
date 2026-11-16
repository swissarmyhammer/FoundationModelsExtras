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

  /// Clears the stored value of the host, and gives the list that applies
  /// after that.
  ///
  /// A host that has a default list gives that list. The default
  /// implementation saves an empty list and gives `[]`.
  ///
  /// - Returns: The list that applies after the reset, in list order.
  /// - Throws: The error of the storage when it cannot clear the value.
  func resetSources() async throws -> [MarketplaceSource]
}

extension MarketplaceSourceStorage {
  /// Saves an empty list, and gives `[]`.
  ///
  /// A storage that has a default list implements its own
  /// ``MarketplaceSourceStorage/resetSources()``.
  ///
  /// - Returns: An empty list.
  /// - Throws: The error of ``MarketplaceSourceStorage/saveSources(_:)``.
  public func resetSources() async throws -> [MarketplaceSource] {
    try await saveSources([])
    return []
  }
}

/// A ``MarketplaceSourceStorage`` that holds the list in memory.
///
/// Use it in tests, and in a host that does not keep the list after it
/// stops.
public actor InMemoryMarketplaceSourceStorage: MarketplaceSourceStorage {
  /// The stored list, in list order.
  private var sources: [MarketplaceSource]

  /// The list that ``resetSources()`` stores, in list order.
  private let defaultSources: [MarketplaceSource]

  /// Makes a storage that holds `sources`.
  ///
  /// - Parameters:
  ///   - sources: The list at the start. The default is an empty list.
  ///   - defaultSources: The list that ``resetSources()`` stores. The
  ///     default is an empty list.
  public init(sources: [MarketplaceSource] = [], defaultSources: [MarketplaceSource] = []) {
    self.sources = sources
    self.defaultSources = defaultSources
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

  /// Replaces the stored list with the default list.
  ///
  /// The method is `async`. Thus a direct call on this actor uses this
  /// method, and not the default of the protocol extension.
  ///
  /// - Returns: The default list, in list order.
  public func resetSources() async -> [MarketplaceSource] {
    sources = defaultSources
    return sources
  }
}
