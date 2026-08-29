import FoundationModels

/// Declares a single operation: its metadata, its parameters (as stored
/// properties), and its behavior.
///
/// Conforming types are ordinarily produced by the `@Operation` macro over a
/// `@Generable` struct — the macro reads the stored properties to synthesize
/// `parameterMetadata` and emits the verb/noun/description statics. Direct,
/// hand-written conformance is always possible too (see plan.md's "Manual
/// escape hatch"): implement `Generable` yourself and supply the statics and
/// `execute(in:)`.
///
/// `Generable` supplies typed decoding from a `GeneratedContent` payload
/// (`init(_:)`, inherited via `ConvertibleFromGeneratedContent`) and the
/// per-type `GenerationSchema`; `OperationDefinition` adds the metadata and
/// behavior a registry needs on top of that.
public protocol OperationDefinition: Generable, Sendable {
    /// The shared environment `execute(in:)` runs against (e.g. a data
    /// store). Operations fused into the same `OperationTool` share one
    /// `Context` type.
    associatedtype Context: Sendable

    /// The operation's result. `Encodable` keeps it JSON-serializable for
    /// both surfaces the fused tool serves: the JSON string returned to the
    /// model, and the value the CLI prints.
    associatedtype Output: Encodable & Sendable

    /// The action this operation performs (e.g. `"add"`).
    static var verb: String { get }

    /// The resource this operation acts on (e.g. `"note"`).
    static var noun: String { get }

    /// A human- and model-facing summary of what the operation does.
    static var operationDescription: String { get }

    /// One entry per stored property/parameter, in declaration order.
    static var parameterMetadata: [ParamMeta] { get }

    /// The canonical `"verb noun"` identifier the resolver matches against
    /// (e.g. `"add note"`). Defaults to `"\(verb) \(noun)"`.
    static var opString: String { get }

    /// Runs the operation against the shared context.
    func execute(in context: Context) async throws -> Output
}

extension OperationDefinition {
    /// The default `opString`: `"\(verb) \(noun)"`.
    ///
    /// A conforming type only needs to override this if it wants an
    /// `opString` that doesn't follow the standard `"verb noun"` shape.
    public static var opString: String {
        "\(verb) \(noun)"
    }
}
