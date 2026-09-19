import Foundation

/// A snapshot that the store materialized but does not serve yet
/// (marketplace.md §8.4).
///
/// ``MarketplacePolicy/ApplyUpdates/nextLaunch`` writes this record. The
/// snapshot folder is already under `snapshots/`, and the next
/// ``MarketplaceStore/start()`` makes `current` name it. The record thus
/// replaces a timer with a flag on the disk, and it survives a restart.
internal struct MarketplacePendingSnapshot: Sendable, Hashable, Codable {
  /// The commit of the snapshot that waits.
  var sha: String

  /// The `version` field of the catalog of that snapshot, or `nil` when the
  /// catalog has none.
  var catalogVersion: String?

  /// The display id that the marketplace takes when the store serves the
  /// snapshot, or `nil` when the catalog names none.
  var displayID: String?
}

/// What the cache knows about one marketplace (marketplace.md §7.2).
///
/// Every field but ``url`` is optional, because a record starts before the
/// first fetch: the store writes the url, and it fills the rest in as it
/// learns each value.
internal struct MarketplaceStateRecord: Sendable, Hashable, Codable {
  /// The `url` field of the source, as the host wrote it.
  var url: String

  /// The branch or the tag that the store follows, or `nil` for the remote
  /// `HEAD`.
  var ref: String?

  /// The commit that ``MarketplaceStore/pin(_:sha:)`` named, or `nil` when
  /// the host pinned nothing (marketplace.md §8.3).
  ///
  /// The `sha` field of a source is a pin too, but it lives in the
  /// configuration of the host and not here. This field is the pin that the
  /// host set at run time, and a later run reads it back.
  var pinnedSha: String?

  /// Whether ``MarketplaceStore/unpin(_:)`` dropped the pin, or `nil` when
  /// the host never called it (marketplace.md §8.3).
  ///
  /// An unpin beats the `sha` field of the source too, thus the flag says
  /// more than an empty ``pinnedSha``: a later run follows the ref again.
  var unpinned: Bool?

  /// The snapshot that the store materialized and does not serve yet, or
  /// `nil` when nothing waits (marketplace.md §8.4).
  var pending: MarketplacePendingSnapshot?

  /// The commit of the snapshot that `current` names, or `nil` before the
  /// first install.
  var currentSha: String?

  /// The `version` field of the catalog of the current snapshot, or `nil`
  /// when the catalog has none.
  var catalogVersion: String?

  /// The display id of the marketplace: the `name` field of the catalog of
  /// the current snapshot, or `nil` before the first fetch.
  ///
  /// A new process reads it, thus a row shows the same name across a
  /// restart, with no fetch (marketplace.md §5.3).
  var displayID: String?

  /// When the store last asked the remote for its head, or `nil` when it
  /// never asked.
  var lastChecked: Date?

  /// When the store last installed a snapshot, or `nil` before the first
  /// install.
  var lastUpdated: Date?

  /// The message of the last failure, or `nil` when the last attempt was
  /// good.
  var lastError: String?

  /// Creates a record. Only the url is necessary.
  ///
  /// - Parameters:
  ///   - url: The `url` field of the source.
  ///   - ref: The branch or the tag that the store follows.
  ///   - pinnedSha: The commit that the host pinned.
  ///   - currentSha: The commit of the snapshot that `current` names.
  ///   - catalogVersion: The `version` field of the catalog.
  ///   - displayID: The `name` field of the catalog.
  ///   - lastChecked: When the store last asked the remote for its head.
  ///   - lastUpdated: When the store last installed a snapshot.
  ///   - lastError: The message of the last failure.
  init(
    url: String,
    ref: String? = nil,
    pinnedSha: String? = nil,
    currentSha: String? = nil,
    catalogVersion: String? = nil,
    displayID: String? = nil,
    lastChecked: Date? = nil,
    lastUpdated: Date? = nil,
    lastError: String? = nil
  ) {
    self.url = url
    self.ref = ref
    self.pinnedSha = pinnedSha
    self.currentSha = currentSha
    self.catalogVersion = catalogVersion
    self.displayID = displayID
    self.lastChecked = lastChecked
    self.lastUpdated = lastUpdated
    self.lastError = lastError
  }
}

/// The `state.json` file of the cache: one record for each marketplace
/// (marketplace.md §7.2).
///
/// The file sits beside the marketplace folders, at
/// `<cache>/state.json`. ``MarketplaceCache/stateFile(inCacheDirectory:)``
/// names it.
///
/// ```json
/// {
///   "version": 1,
///   "marketplaces": {
///     "swissarmyhammer-skills-1a2b3c4d": { "url": "…", "ref": "main" }
///   }
/// }
/// ```
internal struct MarketplaceState: Sendable, Hashable, Codable {
  /// The `version` field that this build writes.
  static let currentVersion = 1

  /// The name of the state file in the cache directory.
  static let fileName = "state.json"

  /// The format of the file. It is ``currentVersion`` for a file that this
  /// build wrote.
  var version: Int

  /// One record for each marketplace, keyed by its cache folder name.
  var marketplaces: [String: MarketplaceStateRecord]

  /// Creates a state.
  ///
  /// - Parameters:
  ///   - marketplaces: One record for each marketplace, keyed by its cache
  ///     folder name. The default is no record.
  ///   - version: The format of the file. The default is ``currentVersion``.
  init(marketplaces: [String: MarketplaceStateRecord] = [:], version: Int = currentVersion) {
    self.marketplaces = marketplaces
    self.version = version
  }

  /// Decodes a state. A field that is not in the input gets the value of
  /// ``init(marketplaces:version:)``.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when a field has the wrong type.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      marketplaces: try container.decodeIfPresent(
        [String: MarketplaceStateRecord].self, forKey: .marketplaces) ?? [:],
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion)
  }

  /// Reads the state file.
  ///
  /// - Parameter url: The state file.
  /// - Returns: The state, or an empty state when the file is not there. A
  ///   cold start has no file, and that is not an error.
  /// - Throws: The error of the file read or of the JSON decoder.
  static func load(from url: URL) throws -> MarketplaceState {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return MarketplaceState()
    }
    return try decode(from: try Data(contentsOf: url))
  }

  /// Decodes a state from the bytes of a state file.
  ///
  /// - Parameter data: The bytes of the file.
  /// - Returns: The state.
  /// - Throws: The error of the JSON decoder.
  static func decode(from data: Data) throws -> MarketplaceState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MarketplaceState.self, from: data)
  }

  /// Writes the state file in one atomic write, so a reader sees the old
  /// file or the new file and never a half-written one.
  ///
  /// The call makes the cache directory when it is missing.
  ///
  /// - Parameter url: The state file to write.
  /// - Throws: The error of the JSON encoder, of the folder, or of the file
  ///   write.
  func save(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}
