// `extras-demo` — the family's living contract test for
// `FoundationModelsExtras` (plan.md §7): a small runnable that proves the
// package's public surface end-to-end, kept compiling forever. Every
// subcommand's implementation imports `FoundationModelsExtras` the same way
// any downstream consumer would — a plain `import`, no `@testable` access —
// and every filesystem-touching subcommand runs against the checked-in
// `Fixtures/` tree beside these sources, never the real home directory.

import ArgumentParser

/// `extras-demo` — one subcommand per pillar: `stack` (`DotfolderStack`),
/// `render` (the Stencil-backed `TemplateEngine`), and `commands` (the
/// slash-command vocabulary).
@main
struct ExtrasDemo: AsyncParsableCommand {
    /// This tool's command-line configuration: its name, a short summary,
    /// and its three pillar subcommands.
    static let configuration = CommandConfiguration(
        commandName: "extras-demo",
        abstract: "Runnable contract test for FoundationModelsExtras' three pillars.",
        subcommands: [StackCommand.self, RenderCommand.self, CommandsCommand.self]
    )
}
