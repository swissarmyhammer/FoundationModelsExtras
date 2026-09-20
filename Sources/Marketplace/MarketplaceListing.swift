import Foundation

/// One marketplace as a read-only list shows it (marketplace.md §5.3 and
/// §7.2).
///
/// ``MarketplaceStore/listings(of:cacheDirectory:)`` makes one listing for
/// each source. A listing carries what the cache already knows, thus a list
/// command writes a whole row with no fetch and no connection:
///
/// ```swift
/// let rows = MarketplaceStore.listings(of: sources, cacheDirectory: cache)
///   .map { [$0.id, $0.url ?? "-", $0.currentSha ?? "-"] }
/// ```
///
/// The listing tells what the marketplace is, and never how the cache holds
/// it: no field names a folder of the cache or a file in it. Thus a later
/// change of the cache layout breaks no consumer.
public struct MarketplaceListing: Sendable, Hashable {
  /// The name of the marketplace: the `name` field of the catalog of the
  /// snapshot it serves, else the pre-fetch key, else the alias.
  ///
  /// It is the empty text when the source gives none of the three, which
  /// happens only for a source that has a bad URL and no alias. A caller
  /// then writes its own placeholder.
  public var id: String

  /// The pre-fetch key: the alias of the source, else the repository name
  /// without `.git`.
  ///
  /// It is `nil` when the URL of the source is of no supported form, because
  /// the key comes from the parsed location. ``id`` still names such a
  /// source when it has an alias.
  public var key: String?

  /// The normalized URL of the marketplace, or `nil` when the URL of the
  /// source is of no supported form.
  ///
  /// A URL that the parser refuses never reaches a reader. Thus a URL that
  /// carries a user name or a password, which the parser refuses for that
  /// reason, is not in a row that a host shows.
  public var url: String?

  /// The commit of the snapshot that the consumer reads, or `nil` before the
  /// first install.
  public var currentSha: String?

  /// The `version` field of the catalog of that snapshot, or `nil` when the
  /// catalog has none.
  public var catalogVersion: String?

  /// When the store last asked the remote for its head, or `nil` when it
  /// never asked.
  public var lastChecked: Date?

  /// Whether the marketplace is a folder on this computer, which the store
  /// reads with no fetch.
  ///
  /// Such a marketplace has no snapshot of its own, thus it carries no
  /// commit, no catalog version and no last check.
  public var isLocalFolder: Bool

  /// Whether the marketplace holds one commit and follows no ref
  /// (marketplace.md §8.3).
  ///
  /// The pin that ``MarketplaceStore/pin(_:sha:)`` wrote wins over the `sha`
  /// field of the source, and ``MarketplaceStore/unpin(_:)`` beats both.
  public var holdsOneCommit: Bool

  /// The message of the last failure, the message of a source that the
  /// parser refuses, or `nil` when the last attempt was good.
  ///
  /// The text never holds a credential.
  public var lastError: String?

  /// Creates a listing.
  ///
  /// - Parameters:
  ///   - id: The name of the marketplace.
  ///   - key: The pre-fetch key. The default is `nil`.
  ///   - url: The normalized URL. The default is `nil`.
  ///   - currentSha: The commit of the snapshot that the consumer reads. The
  ///     default is `nil`.
  ///   - catalogVersion: The `version` field of the catalog. The default is
  ///     `nil`.
  ///   - lastChecked: When the store last asked the remote for its head. The
  ///     default is `nil`.
  ///   - isLocalFolder: Whether the marketplace is a folder on this
  ///     computer. The default is `false`.
  ///   - holdsOneCommit: Whether the marketplace holds one commit. The
  ///     default is `false`.
  ///   - lastError: The message of the last failure. The default is `nil`.
  public init(
    id: String,
    key: String? = nil,
    url: String? = nil,
    currentSha: String? = nil,
    catalogVersion: String? = nil,
    lastChecked: Date? = nil,
    isLocalFolder: Bool = false,
    holdsOneCommit: Bool = false,
    lastError: String? = nil
  ) {
    self.id = id
    self.key = key
    self.url = url
    self.currentSha = currentSha
    self.catalogVersion = catalogVersion
    self.lastChecked = lastChecked
    self.isLocalFolder = isLocalFolder
    self.holdsOneCommit = holdsOneCommit
    self.lastError = lastError
  }
}

extension MarketplaceListing {
  /// The name of a marketplace that gives no display id, no pre-fetch key
  /// and no alias.
  private static let unnamed = ""

  /// Reads one listing for each source out of the state file of a cache
  /// directory.
  ///
  /// The call reads that one file and nothing else. It opens no connection,
  /// starts no fetch, and writes nothing.
  ///
  /// - Parameters:
  ///   - sources: The marketplaces, in list order.
  ///   - cacheDirectory: The cache directory that holds `state.json`.
  /// - Returns: One listing for each source, in list order. A cache
  ///   directory with no state file gives a listing of the source alone.
  static func listings(
    of sources: [MarketplaceSource], cacheDirectory: URL
  ) -> [MarketplaceListing] {
    let file = MarketplaceCache.stateFile(inCacheDirectory: cacheDirectory)
    let state = (try? MarketplaceState.load(from: file)) ?? MarketplaceState()
    return sources.map { listing(of: $0, state: state) }
  }

  /// The listing of one source.
  ///
  /// - Parameters:
  ///   - source: The source to read.
  ///   - state: The state of the cache directory.
  /// - Returns: The listing. A source whose URL is of no supported form
  ///   gives a listing that carries the message of the parser, so that a
  ///   list shows every source that the host named.
  private static func listing(
    of source: MarketplaceSource, state: MarketplaceState
  ) -> MarketplaceListing {
    do {
      return listing(
        of: source, location: try MarketplaceLocation(source: source),
        key: try MarketplaceIdentity.preFetchKey(for: source), state: state)
    } catch {
      return MarketplaceListing(
        id: source.alias ?? unnamed, lastError: String(describing: error))
    }
  }

  /// The listing of one source whose URL the parser accepted.
  ///
  /// - Parameters:
  ///   - source: The source to read.
  ///   - location: The parsed location of the source.
  ///   - key: The pre-fetch key of the source.
  ///   - state: The state of the cache directory.
  /// - Returns: The listing.
  private static func listing(
    of source: MarketplaceSource, location: MarketplaceLocation, key: String,
    state: MarketplaceState
  ) -> MarketplaceListing {
    guard case .git = location else {
      return MarketplaceListing(
        id: key, key: key, url: location.normalizedURL, isLocalFolder: true)
    }
    let folderName = MarketplaceIdentity.cacheFolderName(
      key: key, normalizedURL: location.normalizedURL)
    let record = state.marketplaces[folderName]
    return MarketplaceListing(
      id: record?.displayID ?? key,
      key: key,
      url: location.normalizedURL,
      currentSha: record?.currentSha,
      catalogVersion: record?.catalogVersion,
      lastChecked: record?.lastChecked,
      holdsOneCommit: holdsOneCommit(record: record, source: source),
      lastError: record?.lastError)
  }

  /// Whether the marketplace holds one commit (marketplace.md §8.3).
  ///
  /// The ladder has three rungs, highest first: the pin that the host set at
  /// run time, the unpin that the host set at run time, then the `sha` field
  /// of the source.
  ///
  /// - Parameters:
  ///   - record: What the cache knows, or `nil` before the first fetch.
  ///   - source: The source, which carries the `sha` field of the host.
  /// - Returns: `true` when the marketplace follows no ref.
  private static func holdsOneCommit(
    record: MarketplaceStateRecord?, source: MarketplaceSource
  ) -> Bool {
    if record?.pinnedSha != nil {
      return true
    }
    if record?.unpinned == true {
      return false
    }
    return source.isPinned
  }
}
