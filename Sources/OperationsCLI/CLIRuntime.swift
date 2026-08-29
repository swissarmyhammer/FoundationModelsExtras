import ArgumentParser
import FoundationModels

/// One named group of subcommands: a noun's verb leaves, or (multi-tool
/// only) a tool's noun nodes.
internal struct CLIGroup: Sendable {
    /// The group's CLI name (a noun or a tool name).
    internal let commandName: String

    /// A human-facing summary shown at this level's `--help`.
    internal let abstract: String

    /// The group's own subcommands, in declaration order.
    internal let subcommands: [ParsableCommand.Type]
}

/// The fully-assembled, immutable command tree `CLIRegistryBuilder` builds
/// once per `OperationCLIDriver.init`, and every computed `static var
/// configuration`/dispatch lookup in this target reads for the scope of one
/// `OperationCLIDriver.run(arguments:)` call via `CLIRuntime.current`.
internal struct CLIRegistry: Sendable {
    /// `RootCommand`'s own displayed name, or `nil` to fall back to
    /// ArgumentParser's own default (the type name `RootCommand` converts
    /// to, `"root-command"` — rarely what a real executable wants to show
    /// in its own usage lines, hence `OperationCLIDriver.init`'s
    /// `executableName` parameter).
    internal let rootCommandName: String?

    /// `RootCommand`'s own subcommands: tool-level nodes with more than one
    /// tool, or the single tool's noun-level nodes directly (collapsed)
    /// with exactly one.
    internal let rootSubcommands: [ParsableCommand.Type]

    /// `RootCommand`'s own `--help` summary: the single tool's description
    /// with exactly one tool, empty (each `ToolNode` carries its own) with
    /// more than one.
    internal let rootAbstract: String

    /// Noun-level group data, keyed by the `ObjectIdentifier` of the
    /// `AnyOperation.definitionType` `CLIRegistryBuilder` chose as that
    /// (tool, noun) pair's representative witness — see `NounNode`.
    internal let nounGroups: [ObjectIdentifier: CLIGroup]

    /// Tool-level group data, keyed the same way — see `ToolNode`. Empty
    /// with exactly one tool (the tool level is collapsed away).
    internal let toolGroups: [ObjectIdentifier: CLIGroup]

    /// Dispatch closures, keyed by the `ObjectIdentifier` of the concrete
    /// leaf `ParsableCommand` type a parse can produce (a macro-generated
    /// `Command` or a `FallbackOperationCommand<Rep>`) — looked up once
    /// `parseAsRoot` returns the matched leaf instance.
    internal let dispatchByCommandType: [ObjectIdentifier: @Sendable (GeneratedContent) async throws -> String]

    /// One line per macro-less operation's synthesized fallback leaf,
    /// listing its flags — appended to `--generate-completion-script`'s
    /// output by `FallbackCompletionAugmenter`, since those flags exist
    /// only in `ParamMeta`, never as real declarations `CompletionsGenerator`
    /// can walk. Empty when every operation is macro-generated.
    internal let fallbackParameterLines: [String]
}

/// The ambient home for the registry `OperationCLIDriver.run(arguments:)` scopes to
/// one call: `RootCommand`/`NounNode`/`ToolNode`'s computed `static var
/// configuration` — which ArgumentParser re-reads on every
/// `parseAsRoot`/`completionScript`/`helpMessage` call — read `current`
/// instead of taking the registry as a parameter, since ArgumentParser's own
/// metatype-based API (`[ParsableCommand.Type]`) has no parameter to thread
/// one through.
///
/// A `@TaskLocal` rather than a plain mutable global: multiple
/// `OperationCLIDriver` instances (one per test, typically) must never
/// observe each other's trees, including when tests run concurrently —
/// task-local values are scoped to the current task's call tree and never
/// leak across sibling tasks, unlike a shared mutable global protected by a
/// lock (which would still let two concurrent `run(arguments:)` calls stomp on each
/// other's registry between the lock's release and the parse completing).
internal enum CLIRuntime {
    @TaskLocal internal static var current: CLIRegistry?
}
