import ArgumentParser
import FoundationModels
import Operations

/// An error raised while assembling an `OperationCLIDriver`'s registry —
/// plan.md's "startup assertion pass" over duplicate names and malformed
/// input, caught once at `OperationCLIDriver.init` rather than at first
/// parse.
public enum OperationCLIDriverError: Error, Sendable, Equatable {
    /// Two or more tools passed to `OperationCLIDriver` share a `name`.
    case duplicateToolName(String)

    /// A tool has no operations; `OperationCLIDriver` requires at least one
    /// per tool to have a noun/verb tree to assemble.
    case emptyTool(String)

    /// Two operations in the same tool share an `opString` (verb/noun
    /// pair).
    case duplicateOperation(tool: String, opString: String)
}

extension OperationCLIDriverError: CustomStringConvertible {
    /// A human-readable summary suitable for CLI and log output.
    public var description: String {
        switch self {
        case let .duplicateToolName(name):
            return "duplicate tool name '\(name)': every tool passed to OperationCLIDriver must have a unique name"
        case let .emptyTool(name):
            return "tool '\(name)' has no operations: OperationCLIDriver requires at least one operation per tool"
        case let .duplicateOperation(tool, opString):
            return
                "tool '\(tool)' declares '\(opString)' more than once: every operation's verb/noun pair must be unique within a tool"
        }
    }
}

/// Assembles a `CLIRegistry` from a set of `AnyOperationTool`s: the
/// noun/verb (or tool/noun/verb) tree of `ParsableCommand` metatypes, the
/// dispatch closures keyed by leaf type, and the completion-augmentation
/// data — all computed once, up front, so every `RootCommand`/`NounNode`/
/// `ToolNode` lookup at parse time is a plain dictionary read.
internal enum CLIRegistryBuilder {
    /// Builds the registry for `tools`.
    ///
    /// - Throws: `OperationCLIDriverError` on a duplicate tool name, an
    ///   empty tool, or two operations in the same tool sharing an
    ///   `opString`.
    internal static func build(tools: [AnyOperationTool], executableName: String?) throws -> CLIRegistry {
        try validateUniqueToolNames(tools)
        try validateOperationsPerTool(tools)

        var nounGroups: [ObjectIdentifier: CLIGroup] = [:]
        var toolGroups: [ObjectIdentifier: CLIGroup] = [:]
        var dispatchByCommandType: [ObjectIdentifier: @Sendable (GeneratedContent) async throws -> String] = [:]
        var fallbackParameterLines: [String] = []

        // Both branches below build every field but `rootSubcommands`/
        // `rootAbstract` identically; capturing the shared fields once here
        // keeps `CLIRegistry`'s full field list in one place instead of two.
        func makeRegistry(rootSubcommands: [ParsableCommand.Type], rootAbstract: String) -> CLIRegistry {
            CLIRegistry(
                rootCommandName: executableName,
                rootSubcommands: rootSubcommands,
                rootAbstract: rootAbstract,
                nounGroups: nounGroups,
                toolGroups: toolGroups,
                dispatchByCommandType: dispatchByCommandType,
                fallbackParameterLines: fallbackParameterLines
            )
        }

        // Single tool: the tool level collapses away, so `RootCommand`'s own
        // subcommands are that tool's noun nodes directly.
        if tools.count == 1, let tool = tools.first {
            let nounNodeTypes = buildNounNodes(
                for: tool,
                nounGroups: &nounGroups,
                dispatchByCommandType: &dispatchByCommandType,
                fallbackParameterLines: &fallbackParameterLines
            )
            return makeRegistry(rootSubcommands: nounNodeTypes, rootAbstract: tool.description)
        }

        // Multiple tools: `RootCommand`'s subcommands are tool-level nodes,
        // each carrying its own noun nodes.
        var toolLevelSubcommands: [ParsableCommand.Type] = []
        for tool in tools {
            let nounNodeTypes = buildNounNodes(
                for: tool,
                nounGroups: &nounGroups,
                dispatchByCommandType: &dispatchByCommandType,
                fallbackParameterLines: &fallbackParameterLines
            )
            let representative = tool.operations[0].definitionType
            toolGroups[ObjectIdentifier(representative)] = CLIGroup(
                commandName: tool.name,
                abstract: tool.description,
                subcommands: nounNodeTypes
            )
            toolLevelSubcommands.append(openedType(for: representative, kind: .toolNode))
        }

        return makeRegistry(rootSubcommands: toolLevelSubcommands, rootAbstract: "")
    }

    /// Builds `tool`'s noun-level `NounNode` metatypes, registering every
    /// noun's group data and every operation's leaf/dispatch pairing along
    /// the way.
    private static func buildNounNodes(
        for tool: AnyOperationTool,
        nounGroups: inout [ObjectIdentifier: CLIGroup],
        dispatchByCommandType: inout [ObjectIdentifier: @Sendable (GeneratedContent) async throws -> String],
        fallbackParameterLines: inout [String]
    ) -> [ParsableCommand.Type] {
        let operationsByNoun = groupedByNoun(tool.operations)

        return operationsByNoun.map { noun, operations in
            let leafTypes = operations.map { operation -> ParsableCommand.Type in
                let leafType = leafCommandType(for: operation)
                dispatchByCommandType[ObjectIdentifier(leafType)] = tool.dispatch
                if operation.commandType == nil {
                    fallbackParameterLines.append(fallbackParameterLine(for: operation))
                }
                return leafType
            }

            let representative = operations[0].definitionType
            nounGroups[ObjectIdentifier(representative)] = CLIGroup(
                commandName: noun,
                abstract: "Operations on \(noun).",
                subcommands: leafTypes
            )
            return openedType(for: representative, kind: .nounNode)
        }
    }

    /// Groups `operations` by `noun`, preserving each noun's first-seen
    /// order and each group's operation order.
    private static func groupedByNoun(_ operations: [CLIOperation]) -> [(noun: String, operations: [CLIOperation])] {
        var order: [String] = []
        var byNoun: [String: [CLIOperation]] = [:]
        for operation in operations {
            if byNoun[operation.noun] == nil {
                order.append(operation.noun)
            }
            byNoun[operation.noun, default: []].append(operation)
        }
        return order.map { ($0, byNoun[$0] ?? []) }
    }

    /// `operation`'s macro-generated leaf type, or a synthesized
    /// `FallbackOperationCommand` for the manual escape hatch.
    private static func leafCommandType(for operation: CLIOperation) -> ParsableCommand.Type {
        operation.commandType ?? openedType(for: operation.definitionType, kind: .fallbackLeaf)
    }

    /// One `--generate-completion-script` augmentation line for a
    /// macro-less operation's fallback leaf — see
    /// `CLIRegistry.fallbackParameterLines`.
    private static func fallbackParameterLine(for operation: CLIOperation) -> String {
        let flags = operation.parameters.map { "--\($0.name)" }.joined(separator: ", ")
        return "#   \(operation.opString): \(flags)"
    }

    /// Which generic witness type `openedType(for:kind:)` should produce.
    private enum WitnessKind {
        /// `NounNode<Rep>`.
        case nounNode

        /// `ToolNode<Rep>`.
        case toolNode

        /// `FallbackOperationCommand<Rep>`.
        case fallbackLeaf
    }

    /// Opens `definitionType` as a generic witness type, selecting which of
    /// `NounNode<Rep>`/`ToolNode<Rep>`/`FallbackOperationCommand<Rep>` to
    /// produce via `kind` — the single place `Rep` is recovered from the
    /// existential, shared by every witness-typed metatype this builder
    /// produces (see `AnyOperationTool`'s documentation on opened
    /// existentials).
    private static func openedType(for definitionType: any OperationDefinition.Type, kind: WitnessKind) -> ParsableCommand.Type {
        func open<Rep: OperationDefinition>(_ type: Rep.Type) -> ParsableCommand.Type {
            switch kind {
            case .nounNode: return NounNode<Rep>.self
            case .toolNode: return ToolNode<Rep>.self
            case .fallbackLeaf: return FallbackOperationCommand<Rep>.self
            }
        }
        return open(definitionType)
    }

    /// Validates that no two `tools` share a `name`.
    private static func validateUniqueToolNames(_ tools: [AnyOperationTool]) throws {
        try validateUnique(tools.map(\.name), errorForDuplicate: OperationCLIDriverError.duplicateToolName)
    }

    /// Validates that every tool has at least one operation, and that no
    /// two operations in the same tool share an `opString`.
    private static func validateOperationsPerTool(_ tools: [AnyOperationTool]) throws {
        for tool in tools {
            guard !tool.operations.isEmpty else {
                throw OperationCLIDriverError.emptyTool(tool.name)
            }
            try validateUnique(tool.operations.map(\.opString)) { opString in
                .duplicateOperation(tool: tool.name, opString: opString)
            }
        }
    }

    /// Validates that `keys` contains no duplicates, throwing
    /// `errorForDuplicate` applied to the first repeated key.
    ///
    /// Shared by `validateUniqueToolNames` and `validateOperationsPerTool`,
    /// which otherwise differ only in which keys they check and which
    /// `OperationCLIDriverError` case they throw.
    private static func validateUnique(_ keys: [String], errorForDuplicate: (String) -> OperationCLIDriverError) throws {
        var seen: Set<String> = []
        for key in keys {
            guard seen.insert(key).inserted else {
                throw errorForDuplicate(key)
            }
        }
    }
}
