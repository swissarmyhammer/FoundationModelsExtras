import ArgumentParser
import FoundationModels
import Operations

/// The CLI leaf `CLIRegistryBuilder` synthesizes for a manually-conformed
/// (macro-less) `OperationDefinition` — plan.md's "Manual escape hatch" has
/// no `@Operation`-generated `Command`, so this is the fallback.
///
/// Generic over `Rep: OperationDefinition` for the same reason as
/// `NounNode`/`ToolNode`: ArgumentParser needs a distinct nominal type per
/// leaf, and `Rep` supplies it while also supplying this leaf's actual data
/// (`verb`/`operationDescription`/`parameterMetadata`) directly — no ambient
/// registry lookup needed, unlike `NounNode`/`ToolNode`.
///
/// Unlike the macro-generated `Command`, this leaf has no real `@Option`/
/// `@Flag` per parameter (there's nothing for `@Operation` to have read at
/// compile time): every argument is captured into `rawArguments` and
/// resolved against `Rep.parameterMetadata` by `FallbackPayloadBuilder` at
/// `operationPayload()` time. This is strictly less capable than the macro
/// path — no combined short flags, no per-flag shell completion — which is
/// exactly the trade-off plan.md's "Manual escape hatch" accepts.
internal struct FallbackOperationCommand<Rep: OperationDefinition>: AsyncParsableCommand, OperationCommand {
    internal static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: Rep.verb,
            abstract: Rep.operationDescription,
            discussion: FallbackParameterFormatting.discussion(for: Rep.parameterMetadata)
        )
    }

    /// Every argument this leaf's `@Option`/`@Flag`-less declaration
    /// doesn't recognize — which, since it declares no other properties, is
    /// all of them.
    @Argument(parsing: .allUnrecognized)
    internal var rawArguments: [String] = []

    internal init() {}

    /// The canonical `op` + fields payload resolved from `rawArguments`
    /// against `Rep.parameterMetadata`, in the identical shape
    /// `AnyOperation.run` expects and the model path sends.
    internal func operationPayload() -> GeneratedContent {
        FallbackPayloadBuilder.payload(opString: Rep.opString, parameters: Rep.parameterMetadata, rawArguments: rawArguments)
    }

    /// Mirrors the macro-generated `Command.run()`'s own print-only
    /// behavior for parity when this leaf is driven directly (outside
    /// `OperationCLIDriver`, which always intercepts before `run()` runs —
    /// see `OperationCLIDriver.dispatch(command:)`).
    internal mutating func run() async throws {
        print(operationPayload().jsonString)
    }
}

/// Resolves a `FallbackOperationCommand`'s captured raw arguments against
/// its operation's declared parameters into the canonical payload shape.
internal enum FallbackPayloadBuilder {
    /// Builds the canonical `op` + fields payload for `opString` from
    /// `rawArguments`, resolved against `parameters`.
    ///
    /// - Parameters:
    ///   - opString: The operation's canonical `"verb noun"` identifier,
    ///     written to the payload's `op` field.
    ///   - parameters: The operation's declared parameters.
    ///   - rawArguments: The leaf's captured, unparsed CLI tokens.
    /// - Returns: The resolved payload; a parameter with no recognized
    ///   value in `rawArguments` is simply omitted (a required parameter's
    ///   absence is caught downstream by the dispatched tool's own
    ///   resolver, exactly as it would be for a model-supplied payload).
    internal static func payload(opString: String, parameters: [ParamMeta], rawArguments: [String]) -> GeneratedContent {
        let collected = collectRawValues(parameters: parameters, rawArguments: rawArguments)
        var properties: [(String, any ConvertibleToGeneratedContent)] = [(OperationKeys.opFieldName, opString)]
        for parameter in parameters {
            if let value = convertedValue(collected: collected, parameter: parameter) {
                properties.append((parameter.name, value))
            }
        }
        return GeneratedContent(properties: properties, uniquingKeysWith: { _, new in new })
    }

    /// Raw string values collected from `rawArguments`, before type
    /// conversion: every occurrence of a scalar/array parameter's flag, and
    /// which boolean parameters' flags were present at all.
    private struct CollectedValues {
        // `fileprivate`, not `private`: Swift's `private` scope only runs
        // from a nested type *outward* to its enclosing declaration (code
        // inside `CollectedValues` can see `FallbackPayloadBuilder`'s
        // `private` members), not the other way around — `private` here
        // would make these inaccessible to sibling members like
        // `collectRawValues`/`convertedValue`, which need to read and
        // write them (confirmed by the compiler, not just documentation).
        fileprivate var stringValues: [String: [String]] = [:]
        fileprivate var flags: Set<String> = []
    }

    /// Scans `rawArguments` for each parameter's `--name`/`-short` flag,
    /// consuming `--name=value`, `--name value`, and repeated occurrences.
    private static func collectRawValues(parameters: [ParamMeta], rawArguments: [String]) -> CollectedValues {
        let parametersByFlagName = flagNameIndex(for: parameters)
        var collected = CollectedValues()
        var index = rawArguments.startIndex

        while index < rawArguments.endIndex {
            let token = rawArguments[index]
            index = rawArguments.index(after: index)
            let (flagName, inlineValue) = splitInlineValue(token: token)
            guard let parameter = parametersByFlagName[flagName] else { continue }

            if parameter.type == .boolean {
                collected.flags.insert(parameter.name)
            } else if let inlineValue {
                collected.stringValues[parameter.name, default: []].append(inlineValue)
            } else if index < rawArguments.endIndex {
                collected.stringValues[parameter.name, default: []].append(rawArguments[index])
                index = rawArguments.index(after: index)
            }
        }
        return collected
    }

    /// Maps every parameter's `--name` (and `-short`, if declared) flag
    /// spelling to itself, for `collectRawValues`'s single-pass lookup.
    private static func flagNameIndex(for parameters: [ParamMeta]) -> [String: ParamMeta] {
        var index: [String: ParamMeta] = [:]
        for parameter in parameters {
            index["--\(parameter.name)"] = parameter
            if let short = parameter.short {
                index["-\(short)"] = parameter
            }
        }
        return index
    }

    /// Splits `--name=value` into `("--name", "value")`; returns `(token,
    /// nil)` unchanged for every other form (`--name`, `-s`, a bare value).
    private static func splitInlineValue(token: String) -> (flagName: String, inlineValue: String?) {
        guard token.hasPrefix("--"), let equalsIndex = token.firstIndex(of: "=") else {
            return (token, nil)
        }
        return (String(token[token.startIndex..<equalsIndex]), String(token[token.index(after: equalsIndex)...]))
    }

    /// Converts `collected`'s raw values for `parameter` to the typed value
    /// its declared `ParamType` calls for, or `nil` if it has none.
    private static func convertedValue(collected: CollectedValues, parameter: ParamMeta) -> (any ConvertibleToGeneratedContent)? {
        if parameter.type == .boolean {
            return collected.flags.contains(parameter.name)
        }
        guard let rawValues = collected.stringValues[parameter.name], !rawValues.isEmpty else {
            return nil
        }
        return convertedScalarOrArray(rawValues: rawValues, type: parameter.type)
    }

    /// Converts `rawValues` to `type`'s Swift representation: the last
    /// occurrence for a scalar, every occurrence for an array.
    ///
    /// `type` is never `.boolean` here: `convertedValue` handles booleans
    /// itself and returns before reaching this function.
    private static func convertedScalarOrArray(rawValues: [String], type: ParamType) -> (any ConvertibleToGeneratedContent)? {
        switch type {
        case .string:
            return rawValues.last
        case .integer:
            return convertedIfLastElementParses(rawValues: rawValues, using: Int.init)
        case .number:
            return convertedIfLastElementParses(rawValues: rawValues, using: Double.init)
        case .array(let element):
            return convertedArray(rawValues: rawValues, elementType: element)
        default:
            preconditionFailure("convertedValue handles .boolean before calling convertedScalarOrArray")
        }
    }

    /// Converts `rawValues`' last element with `parse`, or `nil` if there is
    /// none or it fails to parse.
    private static func convertedIfLastElementParses<Value: ConvertibleToGeneratedContent>(
        rawValues: [String],
        using parse: (String) -> Value?
    ) -> Value? {
        rawValues.last.flatMap(parse)
    }

    /// Converts every element of `rawValues` to `elementType`'s Swift
    /// representation, or `nil` if any element fails to convert or
    /// `elementType` is itself an array (nested arrays have no CLI
    /// representation, matching the macro leaf's own `commandFieldKind`
    /// restriction).
    private static func convertedArray(rawValues: [String], elementType: ParamType) -> (any ConvertibleToGeneratedContent)? {
        switch elementType {
        case .string:
            return rawValues
        case .integer:
            return convertedIfEveryElementParses(rawValues: rawValues, using: Int.init)
        case .number:
            return convertedIfEveryElementParses(rawValues: rawValues, using: Double.init)
        case .boolean:
            return convertedIfEveryElementParses(rawValues: rawValues, using: { Bool($0) })
        case .array:
            return nil
        }
    }

    /// Converts every element of `rawValues` with `parse`, or `nil` if any
    /// element fails to parse.
    private static func convertedIfEveryElementParses<Value: ConvertibleToGeneratedContent>(
        rawValues: [String],
        using parse: (String) -> Value?
    ) -> [Value]? {
        let values = rawValues.compactMap(parse)
        return values.count == rawValues.count ? values : nil
    }
}

/// Formats a macro-less operation's parameters for
/// `FallbackOperationCommand`'s `--help` output, since it has no real
/// `@Option`/`@Flag` declarations for ArgumentParser's own help generator to
/// describe.
internal enum FallbackParameterFormatting {
    /// One line per parameter (flag spelling, type, requiredness,
    /// description), or `""` if `parameters` is empty.
    internal static func discussion(for parameters: [ParamMeta]) -> String {
        guard !parameters.isEmpty else { return "" }
        let lines = parameters.map(parameterLine)
        return (["Parameters (resolved manually; this operation has no macro-generated CLI leaf):"] + lines)
            .joined(separator: "\n")
    }

    /// One `--help`/completion-facing line describing `parameter`.
    private static func parameterLine(parameter: ParamMeta) -> String {
        let requiredness = parameter.required ? "" : " (optional)"
        return "  --\(parameter.name) <\(typeName(type: parameter.type))>\(requiredness): \(parameter.description)"
    }

    /// A short, human-facing name for `type`, used in `parameterLine`.
    private static func typeName(type: ParamType) -> String {
        switch type {
        case .string: return "string"
        case .integer: return "int"
        case .number: return "number"
        case .boolean: return "flag"
        case .array(let element): return "\(typeName(type: element))..."
        }
    }
}
