/// The skills that a host takes from one marketplace.
///
/// The materializer copies only the selected skills. Thus a skill that is not
/// selected does not exist for the consumer. A selected name that is not in
/// the marketplace gets a diagnostic. It is not an error.
///
/// ``all`` also takes every agent of the marketplace. ``skills(_:)`` names
/// skills only, thus it takes no agent.
///
/// In a configuration file, ``all`` is the string `all`. ``skills(_:)`` is a
/// map with one key: `skills: [...]`.
public enum SkillSelection: Sendable, Hashable, Codable {
  /// Every skill and every agent of the marketplace. This is the default.
  case all

  /// Only the named skills, and no agent.
  case skills([String])

  /// The string that encodes ``all``.
  private static let allValue = "all"

  /// The text of the error for a value that is not a selection.
  private static let formDescription =
    #"A skill selection is the string "all", or a map with the one key "skills"."#

  /// The keys of the map form.
  private enum CodingKeys: String, CodingKey {
    case skills
  }

  /// Decodes a selection from its configuration form.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when the value is not the string `all`, or
  ///   not a map with the one key `skills`.
  public init(from decoder: any Decoder) throws {
    if let text = try? decoder.singleValueContainer().decode(String.self) {
      guard text == Self.allValue else {
        throw Self.formError(at: decoder.codingPath)
      }
      self = .all
      return
    }
    let container = try decoder.container(keyedBy: AnyKey.self)
    guard container.allKeys.map(\.stringValue) == [CodingKeys.skills.rawValue] else {
      throw Self.formError(at: decoder.codingPath)
    }
    self = .skills(try decoder.container(keyedBy: CodingKeys.self).decode([String].self, forKey: .skills))
  }

  /// Encodes the selection in its configuration form.
  ///
  /// - Parameter encoder: The encoder to write to.
  /// - Throws: The error of the encoder.
  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .all:
      var container = encoder.singleValueContainer()
      try container.encode(Self.allValue)
    case .skills(let names):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(names, forKey: .skills)
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

/// A coding key that takes any text, so that the decoder of
/// ``SkillSelection`` sees each key of a map, a key that it does not know
/// too.
private struct AnyKey: CodingKey {
  /// The text of the key.
  let stringValue: String

  /// The number of the key. A map key has none.
  let intValue: Int? = nil

  /// Makes a key from its text.
  ///
  /// - Parameter stringValue: The text of the key.
  init(stringValue: String) {
    self.stringValue = stringValue
  }

  /// A map key is never a number, thus this gives no key.
  ///
  /// - Parameter intValue: The number of the key.
  init?(intValue: Int) {
    nil
  }
}
