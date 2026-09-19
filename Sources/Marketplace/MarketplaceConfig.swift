import Foundation
import FoundationModelsExtras
import Yams

/// The marketplace source list of a `marketplaces.yaml` file
/// (marketplace.md §6.3).
///
/// The host gives the source list in code (plan.md decision 29). This type is
/// a convenience, in the same way as `DotfolderStack`: it reads the list from
/// the user layer and, when the host trusts the folder, from the project
/// layer.
///
/// ```yaml
/// marketplaces:            # left to right; the last entry wins
///   - url: https://github.com/swissarmyhammer/skills.git
///   - url: github:acme/team-skills
///     ref: stable
///     autoUpdate: false
/// ```
public struct MarketplaceConfig: Sendable, Hashable, Codable {
  /// The name of the configuration file in a layer.
  public static let fileName = "marketplaces.yaml"

  /// The marketplace sources, left to right. A later entry wins over an
  /// earlier entry.
  public var marketplaces: [MarketplaceSource]

  /// Creates a configuration.
  ///
  /// - Parameter marketplaces: The marketplace sources, left to right.
  public init(marketplaces: [MarketplaceSource]) {
    self.marketplaces = marketplaces
  }

  /// Reads `marketplaces.yaml` from the user layer and, when
  /// `includeProject` is `true`, from the project layer, and merges the
  /// lists.
  ///
  /// The project list comes after the user list, so a project entry wins.
  /// When a project entry has the same merge key as a user entry, the
  /// project entry replaces the user entry completely, in the position of
  /// the project entry. There is no field merge. The merge key is the
  /// `alias`, else the normalized URL. A layer with no file adds no entry.
  ///
  /// - Important: A project file is a trust risk, because a cloned
  ///   repository can add a remote source. Set `includeProject` to `true`
  ///   only for a folder that the user trusts.
  ///
  /// - Parameters:
  ///   - stack: The stack to read. Only its `.user` and `.project` layers
  ///     are read, in stack order.
  ///   - includeProject: Whether to read the `.project` layer.
  /// - Returns: The merged configuration.
  /// - Throws: ``MarketplaceConfigError`` when a file cannot be read or is
  ///   not a valid configuration. The error names the file.
  public static func load(from stack: DotfolderStack, includeProject: Bool) throws -> MarketplaceConfig {
    let lists = try stack.layers
      .filter { reads($0.source, includeProject: includeProject) }
      .map { try sources(in: $0) }
    return MarketplaceConfig(marketplaces: lists.reduce([]) { lower, higher in merged(higher, over: lower) })
  }

  /// Writes the configuration as YAML, for the CLI `add` and `remove`
  /// commands.
  ///
  /// The call makes the folder of the file when it is missing, and it
  /// replaces the file in one atomic write.
  ///
  /// - Parameter url: The file to write.
  /// - Throws: The error of the YAML encoder, of the folder, or of the file
  ///   write.
  public func save(to url: URL) throws {
    let text = try YAMLEncoder().encode(self)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Load steps

  /// Tells whether ``load(from:includeProject:)`` reads a layer of this
  /// source.
  ///
  /// - Parameters:
  ///   - source: The source of the layer.
  ///   - includeProject: Whether the host trusts the project layer.
  /// - Returns: `true` for `.user`, `includeProject` for `.project`, and
  ///   `false` for the other layers.
  private static func reads(_ source: DotfolderStack.Source, includeProject: Bool) -> Bool {
    switch source {
    case .user: true
    case .project: includeProject
    case .defaults, .marketplace: false
    }
  }

  /// Reads the sources of the configuration file of one layer.
  ///
  /// - Parameter layer: The layer.
  /// - Returns: The sources in file order, or an empty list when the layer
  ///   has no configuration file.
  /// - Throws: ``MarketplaceConfigError`` that names the file.
  private static func sources(in layer: DotfolderStack.Layer) throws -> [MarketplaceSource] {
    let file = layer.root.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: file.path) else {
      return []
    }
    do {
      let text = try String(contentsOf: file, encoding: .utf8)
      return try YAMLDecoder().decode(MarketplaceConfig.self, from: text).marketplaces
    } catch {
      throw MarketplaceConfigError(file: file, underlyingError: error)
    }
  }

  /// Puts a higher list after a lower list. An entry of the lower list
  /// that has the merge key of an entry of the higher list is removed.
  ///
  /// Entries of one list that have the same key stay: the store finds that
  /// configuration error and records a diagnostic.
  ///
  /// - Parameters:
  ///   - higher: The list that wins.
  ///   - lower: The list that loses.
  /// - Returns: The lower entries that no higher entry replaces, then the
  ///   higher entries.
  private static func merged(_ higher: [MarketplaceSource], over lower: [MarketplaceSource]) -> [MarketplaceSource] {
    let replacedKeys = Set(higher.map(MergeKey.init(source:)))
    return lower.filter { !replacedKeys.contains(MergeKey(source: $0)) } + higher
  }

  /// The identity that tells whether a higher entry replaces a lower entry.
  ///
  /// An alias and a URL are different cases, so an alias never matches a
  /// URL with the same text.
  private enum MergeKey: Hashable {
    /// The alias of the source.
    case alias(String)

    /// The normalized URL of the source, or the `url` text when the URL
    /// is not a §5.1 form.
    case url(String)

    /// Makes the key of `source`: its alias, else its normalized URL.
    ///
    /// Only the `url` field decides a URL key. The `ref` and `sha`
    /// fields do not. A URL that does not parse keeps its text as the
    /// key: the loader does not validate sources, and the store records
    /// a diagnostic for that source later.
    ///
    /// - Parameter source: The source.
    init(source: MarketplaceSource) {
      if let alias = source.alias {
        self = .alias(alias)
      } else {
        let location = try? MarketplaceLocation(source: MarketplaceSource(source.url))
        self = .url(location?.normalizedURL ?? source.url)
      }
    }
  }
}
