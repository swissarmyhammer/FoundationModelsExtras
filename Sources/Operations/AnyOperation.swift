import FoundationModels
import Foundation

/// A type-erased `OperationDefinition`, keyed to a shared `Context`.
///
/// `OperationDefinition` carries associated types (`Context`, `Output`), so
/// a registry that mixes many operation types together — the whole point of
/// fusing them into one `OperationTool` — has to erase those types away.
/// `AnyOperation` captures an operation's metadata plus a closure, `run`,
/// that decodes a `GeneratedContent` payload into the concrete operation
/// type, executes it, and re-encodes the result as JSON. Dispatch always
/// flows through the typed struct — `run` never touches raw dictionaries.
public struct AnyOperation<Context: Sendable>: Sendable {
    /// The action this operation performs (e.g. `"add"`).
    public let verb: String

    /// The resource this operation acts on (e.g. `"note"`).
    public let noun: String

    /// A human- and model-facing summary of what the operation does.
    public let description: String

    /// One entry per parameter, in declaration order.
    public let parameters: [ParamMeta]

    /// The concrete `OperationDefinition` type this `AnyOperation` erases,
    /// type-erased in turn to `any OperationDefinition.Type`.
    ///
    /// `OperationsCLI`'s driver opens this existential (`Rep.Type` generic
    /// parameters bound to it) to obtain distinct nominal witness types when
    /// assembling its runtime command tree — see plan.md's "generic
    /// `NounNode<Rep>` instantiated per noun via opened existentials".
    public let definitionType: any OperationDefinition.Type

    /// The macro-generated CLI leaf command for this operation, if
    /// `definitionType` conforms to `HasCLICommand` — `nil` for an operation
    /// using the manual escape hatch (plan.md's "Manual escape hatch"),
    /// which has no macro-generated `Command` to offer.
    public let commandType: (any OperationCommand.Type)?

    /// The canonical `"verb noun"` identifier the resolver and schema
    /// fusion match against (e.g. `"add note"`).
    ///
    /// Mirrors `OperationDefinition.opString`'s default rendering; computed
    /// from `verb`/`noun` rather than stored separately, so it can never
    /// drift from them.
    public var opString: String {
        "\(verb) \(noun)"
    }

    /// Decodes `content` into the concrete operation type, executes it
    /// against `context`, and returns the JSON-encoded result.
    ///
    /// Throws `OperationError.decodingFailed` if the concrete operation's
    /// `init(_:)` throws; throws `OperationError.executionFailed` if
    /// `execute(in:)` throws; throws `OperationError.encodingFailed` if
    /// JSON-encoding its `Output` throws, or if the encoded JSON isn't valid
    /// UTF-8.
    internal let run: @Sendable (GeneratedContent, Context) async throws -> String

    /// Erases `O` into an `AnyOperation` sharing `O`'s `Context`.
    public init<O: OperationDefinition>(_ type: O.Type) where O.Context == Context {
        verb = O.verb
        noun = O.noun
        description = O.operationDescription
        parameters = O.parameterMetadata
        definitionType = O.self
        commandType = (O.self as? any HasCLICommand.Type)?.commandType
        run = { content, context in
            let operation: O
            do {
                operation = try O(content)
            } catch {
                throw OperationError.decodingFailed
            }

            let output: O.Output
            do {
                output = try await operation.execute(in: context)
            } catch {
                throw OperationError.executionFailed
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(output)
            } catch {
                throw OperationError.encodingFailed
            }

            guard let json = String(data: data, encoding: .utf8) else {
                throw OperationError.encodingFailed
            }
            return json
        }
    }
}
