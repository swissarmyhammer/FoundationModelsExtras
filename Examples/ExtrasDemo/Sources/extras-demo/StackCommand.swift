import ArgumentParser
import Foundation
import FoundationModelsExtras

/// `extras-demo stack` — pillar 2 (plan.md §7): builds `DotfolderStack` over
/// the fixture tree, resolves `config.yaml` and enumerates `commands/*.md`,
/// printing which layer won each item — source tracking made visible.
/// Honors `EXTRASDEMO_DEFAULTS_DIR` (via `DotfolderStack`'s own dev-override
/// seam), so repointing it changes the answers with no rebuild.
struct StackCommand: AsyncParsableCommand {
    /// This subcommand's command-line configuration.
    static let configuration = CommandConfiguration(
        commandName: "stack",
        abstract: "Resolves config.yaml and enumerates commands/*.md, printing which layer won each item."
    )

    /// The config file resolved and reported by this command, relative to a
    /// layer's root.
    private static let configFileName = "config.yaml"

    /// Resolves `config.yaml` and enumerates `commands/*.md` over the demo
    /// stack, printing the winning layer for each.
    func run() throws {
        let stack = DemoFixtures.makeStack()

        if let configURL = stack.nearest(Self.configFileName),
            let source = winningSource(of: configURL, in: stack)
        {
            print("\(Self.configFileName) -> \(label(for: source)) (\(configURL.path))")
        } else {
            print("\(Self.configFileName) -> not found")
        }

        print("commands:")
        let located = stack.enumerate("commands", suffix: ".md")
        for name in located.keys.sorted() {
            guard let entry = located[name] else { continue }
            print("  \(name) -> \(label(for: entry.layer.source))")
        }
    }

    /// The layer whose root is a prefix of `url`'s path, searched highest
    /// precedence first. `nearest`/`locate` return bare URLs with no
    /// attached source, unlike `enumerate`'s `Located` values, so a single
    /// resolved file needs this lookup to report which layer won it.
    private func winningSource(of url: URL, in stack: DotfolderStack) -> DotfolderStack.Source? {
        stack.layers.reversed().first { url.path.hasPrefix($0.root.path) }?.source
    }

    /// Short labels for each `DotfolderStack.Source`, matching this
    /// command's output format — a data table instead of parallel
    /// switch-case branches, so adding a source needs no new arm here.
    private static let sourceLabels: [DotfolderStack.Source: String] = [
        .defaults: "defaults",
        .user: "user",
        .project: "project",
    ]

    /// A short label for `source`, matching this command's output format.
    private func label(for source: DotfolderStack.Source) -> String {
        Self.sourceLabels[source] ?? "unknown"
    }
}
