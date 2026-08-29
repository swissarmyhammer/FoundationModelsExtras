import FoundationModels
import Operations

/// One `OperationTool<Context>`'s CLI-facing metadata and dispatch entry
/// point, with `Context` erased away.
///
/// `OperationTool.call(arguments:)` already has a `Context`-free signature
/// (`(GeneratedContent) async throws -> String`) — binding it directly as
/// `dispatch` erases `Context` without needing an existential or a second
/// generic parameter anywhere else in `OperationsCLI`. This is what lets
/// `OperationCLIDriver` combine tools with different `Context` types into
/// one multi-tool tree (plan.md's `<executable> <tool> <noun> <verb>`
/// grammar).
public struct AnyOperationTool: Sendable {
    /// The tool's model- and CLI-facing name — the `<tool>` segment of the
    /// multi-tool grammar.
    internal let name: String

    /// A human-facing summary of what the tool does, shown at the
    /// collapsed root level (one tool) or the tool level (more than one).
    internal let description: String

    /// Every operation this tool fuses, with `Context` erased away.
    internal let operations: [CLIOperation]

    /// Dispatches a canonical `op` + fields payload through this tool's
    /// `OperationTool.call(arguments:)` — the identical path a model call
    /// uses.
    internal let dispatch: @Sendable (GeneratedContent) async throws -> String

    /// Erases `tool`'s `Context`, capturing its operations' metadata and
    /// binding `call(arguments:)` as `dispatch`.
    public init<Context>(_ tool: OperationTool<Context>) {
        name = tool.name
        description = tool.description
        operations = tool.operations.map(CLIOperation.init)
        dispatch = tool.call
    }
}

/// One operation's CLI-facing metadata: `AnyOperation<Context>`'s public
/// fields with `Context` (and the Context-bound `run` closure the driver
/// never calls directly — dispatch always goes through the owning tool's
/// `call(arguments:)`, see `AnyOperationTool`) erased away.
internal struct CLIOperation: Sendable {
    /// The action this operation performs (e.g. `"add"`).
    internal let verb: String

    /// The resource this operation acts on (e.g. `"note"`).
    internal let noun: String

    /// A human- and model-facing summary of what the operation does.
    internal let description: String

    /// One entry per parameter, in declaration order.
    internal let parameters: [ParamMeta]

    /// The canonical `"verb noun"` identifier (e.g. `"add note"`).
    internal let opString: String

    /// The concrete `OperationDefinition` type this operation erases,
    /// opened by `CLIRegistryBuilder` as a generic witness for `NounNode`/
    /// `ToolNode`/`FallbackOperationCommand`.
    internal let definitionType: any OperationDefinition.Type

    /// The macro-generated CLI leaf command for this operation, if one
    /// exists — `nil` for the manual escape hatch, which
    /// `CLIRegistryBuilder` synthesizes a `FallbackOperationCommand` for
    /// instead.
    internal let commandType: (any OperationCommand.Type)?

    /// Captures `operation`'s CLI-facing metadata, erasing its `Context`.
    internal init<Context>(_ operation: AnyOperation<Context>) {
        verb = operation.verb
        noun = operation.noun
        description = operation.description
        parameters = operation.parameters
        opString = operation.opString
        definitionType = operation.definitionType
        commandType = operation.commandType
    }
}
