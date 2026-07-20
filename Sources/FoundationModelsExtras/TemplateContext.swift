/// A value stored in a `TemplateContext`, covering the shapes templated
/// dotfolder content needs (plan.md §4): strings, numbers, booleans, and
/// arrays/dictionaries of the same, recursively.
public enum TemplateValue: Sendable {
  /// A text value.
  case string(String)
  /// A numeric value.
  case number(Double)
  /// A boolean value.
  case bool(Bool)
  /// An ordered list of values.
  case array([TemplateValue])
  /// A keyed collection of values.
  case dictionary([String: TemplateValue])

  /// This value, converted to the plain `Any` shape Stencil's own
  /// `Context` consumes (`Stencil.Context(dictionary: [String: Any])`).
  fileprivate var stencilValue: Any {
    switch self {
    case .string(let value):
      return value
    case .number(let value):
      return value
    case .bool(let value):
      return value
    case .array(let values):
      return values.map(\.stencilValue)
    case .dictionary(let values):
      return values.mapValues(\.stencilValue)
    }
  }
}

/// A bag of named values passed into `TemplateEngine.render`. Explicit
/// `TemplateContext` values are the highest rung of the swissarmyhammer
/// variable-precedence ladder (plan.md §4) — above environment variables and
/// well-known system variables — a precedence the engine enforces, not this
/// type; `TemplateContext` itself is just storage.
public struct TemplateContext: Sendable {
  private var values: [String: TemplateValue] = [:]

  /// Creates an empty context.
  public init() {}

  /// Sets `key` to `value`, overwriting any existing value for `key`.
  public mutating func set(key: String, to value: TemplateValue) {
    values[key] = value
  }

  /// Exports the stored values as a `[String: Any]` dictionary — the shape
  /// Stencil's `Context` consumes. Internal: only the `TemplateEngine`
  /// facade (a later task) bridges into Stencil; consumers of this package
  /// never see `Any`.
  func stencilDictionary() -> [String: Any] {
    values.mapValues(\.stencilValue)
  }
}
