/// The skills that a host takes from one marketplace (marketplace.md §6.4).
///
/// The materializer copies only the selected skills. Thus a skill that is not
/// selected does not exist for the consumer. A selected name that is not in
/// the catalog gets a diagnostic. It is not an error.
///
/// In a configuration file, ``all`` is the string `all`. The other cases are a
/// map with one key: `plugins: [...]` or `skills: [...]`.
public enum SkillSelection: Sendable, Hashable, Codable {
  /// Every skill in the catalog. This is the default.
  case all

  /// Only the skills of the named plugins.
  case plugins([String])

  /// Only the named skills.
  case skills([String])

  /// The string that encodes ``all``.
  private static let allValue = "all"

  /// The text of the error for a value that is not a selection.
  private static let formDescription =
    #"A skill selection is the string "all", or a map with one key: "plugins" or "skills"."#

  /// The keys of the map forms.
  private enum CodingKeys: String, CodingKey {
    case plugins
    case skills
  }

  /// Decodes a selection from its configuration form.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when the value is not the string `all`, or
  ///   not a map with exactly one of the keys `plugins` and `skills`.
  public init(from decoder: any Decoder) throws {
    if let text = try? decoder.singleValueContainer().decode(String.self) {
      guard text == Self.allValue else {
        throw Self.formError(at: decoder.codingPath)
      }
      self = .all
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.allKeys.count == 1, let key = container.allKeys.first else {
      throw Self.formError(at: decoder.codingPath)
    }
    let names = try container.decode([String].self, forKey: key)
    self = switch key {
    case .plugins: .plugins(names)
    case .skills: .skills(names)
    }
  }

  /// Encodes the selection in its configuration form.
  ///
  /// - Parameter encoder: The encoder to write to.
  /// - Throws: The error of the encoder.
  public func encode(to encoder: any Encoder) throws {
    guard let keyed = keyedNames else {
      var container = encoder.singleValueContainer()
      try container.encode(Self.allValue)
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(keyed.names, forKey: keyed.key)
  }

  /// The map key and the names of a map form, or `nil` for ``all``.
  private var keyedNames: (key: CodingKeys, names: [String])? {
    switch self {
    case .all: nil
    case .plugins(let names): (.plugins, names)
    case .skills(let names): (.skills, names)
    }
  }

  /// Makes the error for a value that is not a selection.
  ///
  /// - Parameter codingPath: The coding path of the value.
  /// - Returns: A `DecodingError.dataCorrupted` error.
  private static func formError(at codingPath: [any CodingKey]) -> DecodingError {
    .dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: formDescription))
  }
}
