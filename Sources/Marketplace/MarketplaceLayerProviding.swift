import Foundation
import FoundationModelsExtras

/// Where one marketplace skill came from (marketplace.md §9.1).
///
/// A diagnostic carries this value, so a surface can say which marketplace,
/// at which commit, a skill came from. The value never carries a
/// credential: ``MarketplaceCredential`` is a separate value that the
/// transport asks for, and it never becomes part of a URL here.
public struct MarketplaceProvenance: Sendable, Equatable {
  /// The display id of the marketplace: the `name` field of the catalog
  /// after a fetch, else the pre-fetch key (marketplace.md §5.3).
  public var id: String

  /// The `url` field of the source, as the host wrote it.
  public var url: String

  /// The commit of the snapshot that the layer root names, or `nil`
  /// before the first install.
  public var sha: String?

  /// The `version` field of the catalog of that snapshot, or `nil` when
  /// the catalog has none.
  public var catalogVersion: String?

  /// Creates a provenance by directly assigning every field.
  ///
  /// - Parameters:
  ///   - id: The display id of the marketplace.
  ///   - url: The `url` field of the source.
  ///   - sha: The commit of the snapshot. The default is `nil`.
  ///   - catalogVersion: The `version` field of the catalog. The default
  ///     is `nil`.
  public init(id: String, url: String, sha: String? = nil, catalogVersion: String? = nil) {
    self.id = id
    self.url = url
    self.sha = sha
    self.catalogVersion = catalogVersion
  }

  /// How many first characters of ``sha`` a row shows when the catalog
  /// carries no version: the usual short form of a commit.
  private static let shortShaLength = 7

  /// The text a display row shows for this marketplace, for example
  /// `swissarmyhammer-skills@1.2.0` (marketplace.md §9.1).
  ///
  /// The catalog version names the snapshot when the catalog has one.
  /// Without a version, the short commit names it instead, thus a row
  /// still says which snapshot a skill came from. Without a commit too,
  /// the id alone is the text.
  ///
  /// ``url`` is never part of the text: a URL can hold a credential, and
  /// a row must never show one.
  public var displayText: String {
    if let catalogVersion {
      return "\(id)@\(catalogVersion)"
    }
    if let sha {
      return "\(id)@\(sha.prefix(Self.shortShaLength))"
    }
    return id
  }
}

/// One marketplace as the consumer sees it: a layer root plus the
/// provenance of what that root holds (marketplace.md §4.2).
///
/// The root is the stable `<cache>/<id>/current` path, thus it stays the
/// same across an update; only the provenance changes.
public struct MarketplaceLayer: Sendable {
  /// The name of the folder at the root of a layer that holds the agent
  /// files: `<layer root>/agents/<file name>.md`.
  ///
  /// The folder is flat. It holds one `.md` file for each agent, and the
  /// file name is the agent name. A consumer reads the `.md` files of this
  /// folder from each layer of ``MarketplaceLayerProviding/marketplaceLayers()``,
  /// and reads them again on each value of
  /// ``MarketplaceLayerProviding/layerUpdates``, as it does for the skills.
  /// An agent body can include a partial of the partials folder of the same
  /// layer.
  ///
  /// The name is reserved at the layer root: a skill folder with this name
  /// gets a ``MarketplaceDiagnostic``, and the snapshot does not hold it.
  /// This package copies the agent files by name only. It reads no agent
  /// frontmatter.
  public static let agentsDirectoryName = "agents"

  /// The layer itself. Its source is ``FoundationModelsExtras/DotfolderStack/Source/marketplace``,
  /// thus it never renders trusted (marketplace.md §4.3).
  public var layer: DotfolderStack.Layer

  /// Where the skills under ``layer`` came from.
  public var provenance: MarketplaceProvenance

  /// Whether a file watcher watches ``layer`` as it watches a local layer
  /// (marketplace.md §7.4).
  ///
  /// It is `true` for a folder on this computer that the provider reads
  /// directly: an edit in that folder is a file-system event like any other.
  ///
  /// It is `false` for a root that a cache snapshot backs. A snapshot swap
  /// is a symlink rename, which sends no reliable event to a watcher that
  /// holds the old target open, and cleanup of an old snapshot would send a
  /// delete event that names no real change. Such a layer reloads on
  /// ``MarketplaceLayerProviding/layerUpdates`` only.
  public var isWatchable: Bool

  /// Creates a marketplace layer by directly assigning its fields.
  ///
  /// - Parameters:
  ///   - layer: The layer itself.
  ///   - provenance: Where the skills under that layer came from.
  ///   - isWatchable: Whether a file watcher watches the root of the layer.
  ///     The default is `false`, which is the cache-backed root.
  public init(
    layer: DotfolderStack.Layer, provenance: MarketplaceProvenance, isWatchable: Bool = false
  ) {
    self.layer = layer
    self.provenance = provenance
    self.isWatchable = isWatchable
  }
}

/// What a consumer needs from a marketplace store: the layers it puts below
/// its local stack, lowest precedence first, and one signal for each change
/// (marketplace.md §7.4).
///
/// The consumer stays a pure disk reader. It never fetches, and it never
/// waits on the network: it reads the layers that the provider names, and it
/// reads them again when the provider says so. A symlink swap sends no
/// reliable file-system event, thus the signal, and not a file watcher, is
/// what makes a marketplace update reach the consumer.
public protocol MarketplaceLayerProviding: Sendable {
  /// Gives the current marketplace layers, lowest precedence first.
  ///
  /// The consumer calls this again on every update, because the commit
  /// and the catalog version of a layer change while its root stays the
  /// same.
  ///
  /// - Returns: The layers, lowest precedence first.
  func marketplaceLayers() -> [MarketplaceLayer]

  /// One value for each time the marketplace layers changed.
  ///
  /// Each access registers a subscription, thus the consumer takes the
  /// stream one time, at construction.
  var layerUpdates: AsyncStream<Void> { get }
}
