import ArgumentParser
import Foundation
import FoundationModelsExtras

/// `extras-demo agents` — pillar 4 (plan.md §10): walks the fixture
/// `agents/` tree with `AgentsMd.documents(from:)`, printing each
/// discovered document's directory (relative to the fixture repo root) and
/// which alias matched — provenance made visible, same spirit as
/// `extras-demo stack`.
struct AgentsCommand: AsyncParsableCommand {
    /// This subcommand's command-line configuration.
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract:
            "Walks the fixture agent-instructions tree, printing each discovered document's directory and matched alias."
    )

    /// Walks from the fixture's alias-only leaf directory
    /// (`agents/service/api`) up to the fixture's own root
    /// (`agentsRepoRoot`, passed explicitly since a checked-in fixture
    /// cannot carry a real `.git`-detectable marker for `AgentsMd`'s
    /// default root detection), printing one line per discovered document,
    /// outermost first.
    func run() throws {
        let documents = try AgentsMd.documents(
            from: DemoFixtures.agentsLeafDirectory, upTo: DemoFixtures.agentsRepoRoot)

        for document in documents {
            let relativeDirectory = Self.relativePath(
                of: document.directory, from: DemoFixtures.agentsRepoRoot)
            let alias = document.url.lastPathComponent
            print("\(relativeDirectory) -> \(alias) (\(document.url.path))")
        }
    }

    /// `directory`'s path relative to `root` (e.g. `"service/api"`), or
    /// `"."` when `directory` is `root` itself.
    private static func relativePath(of directory: URL, from root: URL) -> String {
        let directoryPath = directory.path
        let rootPath = root.path
        guard directoryPath.hasPrefix(rootPath) else { return directoryPath }
        let suffix = directoryPath.dropFirst(rootPath.count)
        let trimmed = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        return trimmed.isEmpty ? "." : trimmed
    }
}
