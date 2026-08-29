import FoundationModels

/// Re-exported so that any target which imports `Operations` — including
/// macro-generated `Command` types produced by `@Operation` — has
/// `ArgumentParser` available without declaring its own dependency on
/// swift-argument-parser.
@_exported import ArgumentParser

/// Attaches verb, noun, and description metadata to an operation type.
///
/// `@Operation` marks a `Generable` struct as a fused-tool operation: its
/// stored properties are the operation's parameters. This macro synthesizes
/// `OperationDefinition` conformance — the `verb`/`noun`/`operationDescription`
/// statics and a `parameterMetadata: [ParamMeta]` table derived from the
/// struct's stored properties (type mapping, `Optional` ⇒ not required,
/// `@Guide(description:)` / doc-comment description, `@OperationParam`
/// short/aliases/allowedValues).
///
/// It also emits a nested `Command: AsyncParsableCommand, OperationCommand`
/// (ArgumentParser leaf) for the dual-use CLI: a `@Flag`/`@Option` per
/// stored property (`Bool` ⇒ flag, arrays ⇒ repeatable option, `Optional` ⇒
/// non-required option, everything else ⇒ required option), a
/// `CommandConfiguration` named after `verb`, and an `operationPayload()`
/// that serializes the parsed values into the canonical `op` + fields
/// payload — the identical shape the model path sends to `AnyOperation.run`
/// — plus a `CLICommand` typealias satisfying `HasCLICommand`, so
/// `OperationsCLI`'s driver can reach `Command` generically from any
/// `AnyOperation` built over this type.
///
/// - Parameters:
///   - verb: The action the operation performs (e.g. `"add"`).
///   - noun: The resource the operation acts on (e.g. `"note"`).
///   - description: A human- and model-facing summary of what the operation
///     does.
@attached(
    extension, conformances: OperationDefinition, HasCLICommand,
    names: named(verb), named(noun), named(operationDescription), named(parameterMetadata), named(Command),
        named(CLICommand)
)
public macro Operation(verb: String, noun: String, description: String) =
    #externalMacro(module: "OperationsMacros", type: "OperationMacro")

/// Marks a stored property of an `@Operation` struct with CLI-facing
/// affordances that have no `@Generable`/`@Guide` equivalent.
///
/// `@Operation` reads this attribute's arguments while synthesizing
/// `parameterMetadata`, but `@OperationParam` itself expands to nothing — it
/// is a pure marker, inspected as sibling syntax rather than generating any
/// code of its own.
///
/// - Parameters:
///   - short: A single-character CLI short flag (e.g. `"t"` for `--title`).
///   - aliases: Alternate parameter names the forgiving resolver accepts in
///     place of the property's name.
///   - allowedValues: The closed set of string values this parameter
///     accepts, if constrained. Takes precedence over a recognized literal
///     `@Guide(.anyOf([...]))` on the same property.
@attached(peer)
public macro OperationParam(short: Character? = nil, aliases: [String] = [], allowedValues: [String]? = nil) =
    #externalMacro(module: "OperationsMacros", type: "OperationParamMacro")
