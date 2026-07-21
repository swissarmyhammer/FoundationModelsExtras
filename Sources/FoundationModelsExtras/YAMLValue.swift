import Yams

/// A YAML value tree — the shape `LayeredYAMLDocument` merges and consumers
/// decode into their own `Codable` types (plan.md §11). Loosely mirrors the
/// shape of Yams' own `Node` (scalar/mapping/sequence), but is this
/// package's own type: Yams' `Node` never crosses this package's public
/// API surface, only inside this file's implementation.
///
/// `indirect` because `.array`/`.dictionary` recursively contain
/// `YAMLValue` — an ordinary (non-indirect) enum cannot store itself.
public indirect enum YAMLValue: Sendable, Equatable {
  /// A YAML string scalar.
  case string(String)
  /// A YAML integer scalar.
  case int(Int)
  /// A YAML floating-point scalar.
  case double(Double)
  /// A YAML boolean scalar.
  case bool(Bool)
  /// A YAML sequence. Under `LayeredYAMLDocument`'s merge rule, a sequence
  /// replaces wholesale when a later layer defines the same key — never
  /// concatenated or element-merged across layers.
  case array([YAMLValue])
  /// A YAML mapping, keyed by string. Under `LayeredYAMLDocument`'s merge
  /// rule, a mapping merges by key with a later layer's mapping for the
  /// same key — each key's value recursively applying the same rule.
  case dictionary([String: YAMLValue])
  /// YAML's explicit or implicit null (`~`, `null`, or an empty scalar).
  case null
}

/// Errors thrown by `YAMLValue.decoded(as:)` — the package's own error
/// type, mirroring the facade-error style of `LayeredYAMLDocumentError`: no
/// Yams (or other internal) type ever crosses this boundary, only this
/// documented, `CustomStringConvertible` type.
public enum YAMLValueDecodingError: Error, Sendable, CustomStringConvertible {
  /// Decoding `self` as the requested type failed; `message` carries the
  /// underlying `DecodingError` (or other) diagnostic text.
  case decodingFailed(message: String)

  /// A human-readable description of the failure.
  public var description: String {
    switch self {
    case .decodingFailed(let message):
      return "YAMLValue decoding failed: \(message)"
    }
  }
}

extension YAMLValue {
  /// Re-encodes this value tree into any `Decodable` type — the "Extras
  /// merges trees, consumers decode" story (plan.md §11): `LayeredYAMLDocument`
  /// centralizes only the cross-layer *merge*; the schema (and its own
  /// `CodingKeys`, defaulting, etc.) stays the consumer's.
  ///
  /// **Implementation choice.** This re-encodes `self` into an in-memory
  /// Yams `Node` tree (explicitly tagged per case, so re-resolution can
  /// never guess a different type than the one this value already carries
  /// — e.g. `.string("123")` stays a string, never re-resolved as an int)
  /// and decodes through `YAMLDecoder.decode(_:from: Node)` — Yams' own,
  /// already-tested `Decoder` implementation over its `Node` type, rather
  /// than a hand-rolled `Decoder`/`KeyedDecodingContainer` pair over this
  /// package's own tree. Simpler, and it still satisfies the round-trip
  /// contract; Yams' `Node` never appears in this method's signature, only
  /// transiently inside its body.
  ///
  /// - Parameter type: The `Decodable` type to decode into. Inferred from
  ///   context when omitted, e.g. `let config: Config = try value.decoded()`.
  /// - Returns: The decoded value.
  /// - Throws: `YAMLValueDecodingError.decodingFailed` if `self`'s shape
  ///   does not match `type`'s expectations.
  public func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
    do {
      return try YAMLDecoder().decode(T.self, from: yamsNode())
    } catch {
      throw YAMLValueDecodingError.decodingFailed(message: String(describing: error))
    }
  }

  /// Converts this value into the equivalent Yams `Node` tree, explicitly
  /// tagged per case so `YAMLDecoder` never re-resolves a scalar's type
  /// from its string form.
  fileprivate func yamsNode() -> Node {
    switch self {
    case .string(let value):
      return Node(value, Tag(.str))
    case .int(let value):
      return Node(String(value), Tag(.int))
    case .double(let value):
      return Node(String(value), Tag(.float))
    case .bool(let value):
      return Node(value ? "true" : "false", Tag(.bool))
    case .null:
      // `NSNull.construct(from:)` (what `decodeNil()` ultimately checks)
      // only recognizes a *plain*-style scalar reading `""`/`~`/`null`/
      // `Null`/`NULL` — an explicit tag alone is not enough, so `.plain`
      // style is passed explicitly here.
      return Node("null", Tag(.null), .plain)
    case .array(let values):
      return Node(values.map { $0.yamsNode() }, Tag(.seq))
    case .dictionary(let values):
      return Node(
        values.map { (Node($0.key, Tag(.str)), $0.value.yamsNode()) }, Tag(.map))
    }
  }
}
