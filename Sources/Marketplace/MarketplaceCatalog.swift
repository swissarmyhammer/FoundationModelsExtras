import Foundation

/// The catalog file of a marketplace: `.claude-plugin/marketplace.json`, or
/// the Codex copy `.agents/plugins/marketplace.json` (marketplace.md §5.2).
///
/// The model decodes only the fields that ``CatalogResolver`` uses. It
/// ignores all other keys, for example `description`, `category`, and the
/// Codex `interface` and `policy` keys.
internal struct MarketplaceCatalog: Sendable, Hashable, Decodable {
  /// The owner of a marketplace.
  struct Owner: Sendable, Hashable, Decodable {
    /// The name of the owner.
    var name: String?

    /// The email address of the owner.
    ///
    /// Only the synthesized `Hashable` conformance reads it, and periphery
    /// cannot see that read.
    // periphery:ignore
    var email: String?
  }

  /// The `metadata` object of a catalog.
  struct Metadata: Sendable, Hashable, Decodable {
    /// The release version of the catalog, for example `1.0.0`.
    var version: String?
  }

  /// One plugin entry: a named list of skills and agents.
  struct Plugin: Sendable, Hashable, Decodable {
    /// The name of the plugin.
    var name: String

    /// The location of the files of the plugin.
    var source: PluginSource

    /// The `strict` flag. `false` tells that the plugin needs no
    /// `plugin.json` file.
    var strict: Bool?

    /// The skill folders of the plugin, relative to the plugin source.
    /// When it is `nil`, the skills are the folders of
    /// `<source>/skills/`.
    var skills: [String]?

    /// The agent files of the plugin, relative to the plugin source. When
    /// it is `nil`, the agents are the `.md` files directly in
    /// `<source>/agents/`.
    var agents: [String]?

    /// The keys of a plugin entry.
    private enum CodingKeys: String, CodingKey {
      case name
      case source
      case strict
      case skills
      case agents
    }

    /// Decodes a plugin entry.
    ///
    /// The `agents` value is a list of paths, or one path. One path is a
    /// list of one entry, thus a catalog that writes `"agents": "./x.md"`
    /// stays usable.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when `name` or `source` is missing, or when
    ///   a value has the wrong type.
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      name = try container.decode(String.self, forKey: .name)
      source = try container.decode(PluginSource.self, forKey: .source)
      strict = try container.decodeIfPresent(Bool.self, forKey: .strict)
      skills = try container.decodeIfPresent([String].self, forKey: .skills)
      if let path = try? container.decode(String.self, forKey: .agents) {
        agents = [path]
      } else {
        agents = try container.decodeIfPresent([String].self, forKey: .agents)
      }
    }
  }

  /// The `source` value of a plugin: a string, or an object.
  enum PluginSource: Sendable, Hashable, Decodable {
    /// A path in the marketplace repository: a string, or a Codex object
    /// of the kind `local`.
    case relative(String)

    /// A source outside the marketplace repository, for example
    /// `github`, `git-subdir`, or `url`. v1 does not read it.
    case remote(RemotePluginSource)

    /// The kind of a Codex source object that names a relative path.
    private static let localKind = "local"

    /// The text of the error for a `local` source object with no path.
    private static let missingPathDescription = #"A "local" plugin source must have a "path"."#

    /// Decodes a plugin source from a string or from an object.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the value is not a string and not an
    ///   object with a `source` key, or when a `local` object has no
    ///   `path`.
    init(from decoder: any Decoder) throws {
      if let path = try? decoder.singleValueContainer().decode(String.self) {
        self = .relative(path)
        return
      }
      let object = try RemotePluginSource(from: decoder)
      guard object.kind == Self.localKind else {
        self = .remote(object)
        return
      }
      guard let path = object.path else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(codingPath: decoder.codingPath, debugDescription: Self.missingPathDescription))
      }
      self = .relative(path)
    }
  }

  /// A plugin source object. v1 keeps its fields only to name the source in
  /// a diagnostic.
  struct RemotePluginSource: Sendable, Hashable, Decodable {
    /// The kind of the source, from the `source` key: for example
    /// `github`, `git-subdir`, `url`, or `npm`.
    var kind: String

    /// The git URL of a `git-subdir` or a `url` source.
    var url: String?

    /// The `owner/repo` name of a `github` source.
    var repo: String?

    /// The folder in the repository of the source.
    var path: String?

    /// The branch or the tag.
    ///
    /// Only the synthesized `Hashable` conformance reads it, and periphery
    /// cannot see that read.
    // periphery:ignore
    var ref: String?

    /// The commit pin.
    ///
    /// Only the synthesized `Hashable` conformance reads it, and periphery
    /// cannot see that read.
    // periphery:ignore
    var sha: String?

    /// The keys of a source object. The kind is the `source` key.
    private enum CodingKeys: String, CodingKey {
      case kind = "source"
      case url
      case repo
      case path
      case ref
      case sha
    }
  }

  /// The name of the marketplace. After a fetch, it is the display id
  /// (marketplace.md §5.3).
  var name: String

  /// The owner of the marketplace.
  var owner: Owner?

  /// The `metadata` object.
  var metadata: Metadata?

  /// The plugins, in catalog order.
  var plugins: [Plugin]

  /// The renamed names. An old name maps to its new name, or to `nil` when
  /// the catalog removed the name. The map is empty when the catalog has no
  /// `renames` key.
  var renames: [String: String?]

  /// The keys of a catalog.
  private enum CodingKeys: String, CodingKey {
    case name
    case owner
    case metadata
    case plugins
    case renames
  }

  /// Decodes a catalog. A catalog with no `renames` key gets an empty map.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when `name` or `plugins` is missing, or when
  ///   a value has the wrong type.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    owner = try container.decodeIfPresent(Owner.self, forKey: .owner)
    metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
    plugins = try container.decode([Plugin].self, forKey: .plugins)
    renames = try container.decodeIfPresent([String: String?].self, forKey: .renames) ?? [:]
  }
}
