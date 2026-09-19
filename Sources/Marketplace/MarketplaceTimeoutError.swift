/// A fetch took longer than the `fetchTimeout` of the marketplace policy
/// (marketplace.md §5.1 and §8.2).
///
/// The package has no timeout of its own: this error happens only when the
/// host gives one. The text names no URL and no credential.
internal struct MarketplaceTimeoutError: Error, Equatable, CustomStringConvertible {
  /// Says that the fetch timeout of the policy ended the fetch.
  var description: String {
    "The fetch took longer than the fetch timeout of the policy, thus the store stopped it."
  }
}
