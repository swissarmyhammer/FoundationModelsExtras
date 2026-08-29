/// The primitive shape of an operation parameter's value.
///
/// Mirrors the JSON Schema types `@Generable`/`GenerationSchema` reason
/// about, so `ParamMeta` can describe both the model-facing schema and the
/// CLI-facing argument without inventing a parallel type vocabulary.
public enum ParamType: Sendable, Equatable {
    /// A string primitive type.
    case string

    /// An integer primitive type.
    case integer

    /// A floating-point number primitive type.
    case number

    /// A Boolean primitive type.
    case boolean

    /// A repeatable value of the given element type (a Swift `Array`).
    indirect case array(of: ParamType)
}

/// Metadata describing one operation parameter.
///
/// A macro-generated or hand-conformed `OperationDefinition` publishes one
/// `ParamMeta` per stored property via `parameterMetadata`. This is the
/// single source both the fused `Tool` schema and the CLI leaf command draw
/// from — there is no separate, hand-maintained description of an
/// operation's arguments.
public struct ParamMeta: Sendable, Equatable {
    /// The parameter's canonical name, as it appears in the JSON payload.
    public let name: String

    /// The parameter's value shape.
    public let type: ParamType

    /// Whether the operation fails without this parameter present.
    public let required: Bool

    /// A human- and model-facing summary of what the parameter means.
    public let description: String

    /// An optional single-character CLI short flag (e.g. `-t` for `--title`).
    public let short: Character?

    /// Alternate parameter names the forgiving resolver accepts in place of
    /// `name` (e.g. `"labels"` as an alias for `"tags"`).
    public let aliases: [String]

    /// The closed set of string values this parameter accepts, if
    /// constrained; `nil` when any value of `type` is allowed.
    public let allowedValues: [String]?

    /// Creates a parameter metadata descriptor with the given values.
    public init(
        name: String,
        type: ParamType,
        required: Bool,
        description: String,
        short: Character? = nil,
        aliases: [String] = [],
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.short = short
        self.aliases = aliases
        self.allowedValues = allowedValues
    }
}
