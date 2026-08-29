import ArgumentParser
import Operations

/// The dual-use CLI's root command.
///
/// `AsyncParsableCommand` so `OperationCLIDriver` can drive the whole
/// (possibly async, since every leaf is) tree via `asyncParseAsRoot`. A
/// single, non-generic type — unlike `NounNode`/`ToolNode`, nothing is ever
/// compared against it, so it needs no per-driver-instance type
/// distinctness, only the ambient `CLIRuntime.current` registry
/// `OperationCLIDriver.run(arguments:)` sets for the scope of one call.
///
/// `commandName` reads `CLIRuntime.current?.rootCommandName`: without it,
/// ArgumentParser's own default derives the name shown in usage lines from
/// this *type's* name (`"root-command"`), not a real executable's actual
/// name — see `OperationCLIDriver.init`'s `executableName` parameter.
internal struct RootCommand: AsyncParsableCommand {
    internal static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: CLIRuntime.current?.rootCommandName,
            abstract: CLIRuntime.current?.rootAbstract ?? "",
            subcommands: CLIRuntime.current?.rootSubcommands ?? []
        )
    }
}

/// One noun's verb subcommands (`notes note add`, `notes note delete`, …).
///
/// Generic over `Rep: OperationDefinition` purely so ArgumentParser sees a
/// distinct nominal type per noun — subcommand identity in ArgumentParser is
/// per-*type*, not per-value, so two sibling nouns can't share one type the
/// way two sibling values normally could. `Rep` itself contributes no data:
/// `configuration` reads this noun's actual `commandName`/`abstract`/
/// `subcommands` from the ambient `CLIRuntime.current` registry, keyed by
/// the `ObjectIdentifier` of whichever `AnyOperation.definitionType`
/// `CLIRegistryBuilder` chose as this noun's representative witness (the
/// first operation in the noun's group — any operation in the group would
/// key the same registry entry, since the key only ever identifies *which
/// group*, never anything about the witness type itself).
///
/// See plan.md's "generic `NounNode<Rep>` instantiated per noun via opened
/// existentials": `CLIRegistryBuilder` opens each group's representative
/// `any OperationDefinition.Type` to produce a distinct `NounNode<Rep>.self`
/// metatype per noun, entirely at registry-build time — this type itself
/// never opens anything.
internal struct NounNode<Rep: OperationDefinition>: ParsableCommand {
    internal static var configuration: CommandConfiguration {
        groupCommandConfiguration(for: Rep.self, in: CLIRuntime.current?.nounGroups, defaultingTo: Rep.noun)
    }
}

/// One tool's noun subcommands (`notes note …`, `tasks task …`, …), present
/// only in the multi-tool grammar (`<executable> <tool> <noun> <verb>`);
/// the single-tool grammar collapses this level away (`RootCommand`'s
/// subcommands become the noun nodes directly).
///
/// See `NounNode`'s documentation — the same opened-existential-witness
/// rationale applies, with `CLIRuntime.current?.toolGroups` in place of
/// `nounGroups`.
internal struct ToolNode<Rep: OperationDefinition>: ParsableCommand {
    internal static var configuration: CommandConfiguration {
        groupCommandConfiguration(for: Rep.self, in: CLIRuntime.current?.toolGroups, defaultingTo: "")
    }
}

/// Builds a `NounNode`/`ToolNode`'s `CommandConfiguration` from `groups`'
/// entry for `rep`, falling back to `defaultCommandName` and empty
/// abstract/subcommands when `groups` is `nil` (read outside
/// `OperationCLIDriver.run(arguments:)`'s scope) or has no entry for `rep` (an
/// internal invariant `CLIRegistryBuilder` is responsible for upholding).
private func groupCommandConfiguration<Rep: OperationDefinition>(
    for rep: Rep.Type,
    in groups: [ObjectIdentifier: CLIGroup]?,
    defaultingTo defaultCommandName: String
) -> CommandConfiguration {
    let group = groups?[ObjectIdentifier(rep)]
    return CommandConfiguration(
        commandName: group?.commandName ?? defaultCommandName,
        abstract: group?.abstract ?? "",
        subcommands: group?.subcommands ?? []
    )
}
