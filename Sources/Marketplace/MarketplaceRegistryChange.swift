/// One change that a ``MarketplaceRegistry`` saved to its storage.
///
/// The registry sends a change only after the storage saved the new list.
public enum MarketplaceRegistryChange: Sendable, Hashable {
  /// A marketplace was added to the list.
  ///
  /// ``MarketplaceRegistry/add(_:)`` adds it to the end of the list.
  /// ``MarketplaceRegistry/reset()`` adds it in its position in the default
  /// list.
  ///
  /// - Parameter entry: The new marketplace.
  case added(MarketplaceEntry)

  /// The source of a marketplace was replaced.
  ///
  /// ``MarketplaceRegistry/update(id:to:)`` replaces it in its position.
  /// ``MarketplaceRegistry/reset()`` replaces it with the source of the same
  /// id in the default list.
  ///
  /// - Parameters:
  ///   - previousID: The id of the marketplace before the change. It is
  ///     different from the id of the entry when the new source has a
  ///     different id.
  ///   - entry: The marketplace after the change.
  case updated(previousID: String, MarketplaceEntry)

  /// A marketplace was removed from the list.
  ///
  /// - Parameter entry: The removed marketplace.
  case removed(MarketplaceEntry)
}
