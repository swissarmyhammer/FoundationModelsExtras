/// What a ``MarketplaceStore`` did with one marketplace (marketplace.md
/// §6.2).
///
/// A host reads the events to show progress and to report a failure. The
/// consumer of the layers does not read them: it follows
/// ``MarketplaceLayerProviding/layerUpdates`` instead.
///
/// No case carries a URL or a credential, thus an event that a log line shows
/// holds no secret.
public enum MarketplaceEvent: Sendable, Hashable {
  /// The store read the remote head of the marketplace and downloaded no
  /// content (marketplace.md §8.1).
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - current: The commit that `current` names, or `nil` when the
  ///     marketplace has no snapshot yet.
  ///   - latest: The commit that the remote head names.
  case checked(id: String, current: String?, latest: String)

  /// The remote holds a commit that the snapshot does not, and the store
  /// did not install it: the automatic update is off, or the policy is a
  /// dry run (marketplace.md §8.3).
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - from: The commit that `current` names, or `nil` when the
  ///     marketplace has no snapshot yet.
  ///   - to: The commit that the remote head names.
  case updateAvailable(id: String, from: String?, to: String)

  /// The store installed a new snapshot, and `current` now names it. The
  /// consumer reads the layers again.
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - from: The commit of the snapshot before this one, or `nil` for a
  ///     cold start.
  ///   - to: The commit of the new snapshot.
  case updated(id: String, from: String?, to: String)

  /// The store could not bring the marketplace to its remote head. The last
  /// good snapshot stays in place (marketplace.md §7.5).
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - error: The text of the failure. It never holds a credential.
  ///   - keptVersion: The commit of the snapshot that stays, or `nil` when
  ///     there is none yet.
  case failed(id: String, error: String, keptVersion: String?)
}
