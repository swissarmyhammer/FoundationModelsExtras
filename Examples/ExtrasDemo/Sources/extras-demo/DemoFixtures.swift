import Foundation
import FoundationModelsExtras

/// Fixed fixture paths for the `extras-demo` example (plan.md §7): the
/// checked-in `Fixtures/` tree beside this executable's own sources, so no
/// demo subcommand ever depends on the process's current working directory
/// or touches the real home directory.
enum DemoFixtures {
    /// This source file's own location, resolved at compile time — the seam
    /// that lets every fixture path below be derived without depending on
    /// the process's current working directory.
    private static let sourceFileURL = URL(fileURLWithPath: #filePath)

    /// `Examples/ExtrasDemo/Fixtures/`, three directories up from this file
    /// (`Examples/ExtrasDemo/Sources/extras-demo/DemoFixtures.swift`).
    static let root: URL =
        sourceFileURL
        .deletingLastPathComponent()  // DemoFixtures.swift -> extras-demo/
        .deletingLastPathComponent()  // extras-demo/ -> Sources/
        .deletingLastPathComponent()  // Sources/ -> ExtrasDemo/
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// The shipped-defaults fixture layer.
    static let defaultsDirectory = root.appendingPathComponent("defaults", isDirectory: true)
    /// The fixture standing in for the user's home dotfolder layer.
    static let userDirectory = root.appendingPathComponent("user", isDirectory: true)
    /// The fixture standing in for the current project: its own
    /// `.extrasdemo/` subdirectory is the project layer `DotfolderStack`
    /// derives automatically from this working directory.
    static let projectWorkingDirectory = root.appendingPathComponent("project", isDirectory: true)

    /// The nested repo-like fixture tree for `extras-demo agents` (plan.md
    /// §10): an `AGENTS.md` at the root, an `AGENT.md` migration alias one
    /// level down at `agents/service/`, and a `CLAUDE.md`
    /// ecosystem-compatibility alias — alone, with neither `AGENTS.md` nor
    /// `AGENT.md` beside it — at `agents/service/api/`, the alias-only
    /// directory. `AgentsCommand` passes `agentsRepoRoot` explicitly as
    /// `AgentsMd.documents(from:upTo:)`'s `upTo:` — git tracks no path
    /// component literally named `.git`, so this fixture cannot carry a
    /// real `.git`-detectable marker the way a checked-out repository
    /// would.
    static let agentsRepoRoot = root.appendingPathComponent("agents", isDirectory: true)
    /// The nested leaf directory `extras-demo agents` walks up from —
    /// `agents/service/api`, the alias-only directory.
    static let agentsLeafDirectory = agentsRepoRoot.appendingPathComponent(
        "service/api", isDirectory: true)

    /// Builds the demo's `DotfolderStack` over the checked-in fixture tree.
    /// The environment consulted defaults to the real process environment,
    /// so the `EXTRASDEMO_DEFAULTS_DIR` dev-override seam works with no code
    /// change — pointing it elsewhere repoints the `stack` subcommand's
    /// answers with no rebuild.
    static func makeStack() -> DotfolderStack {
        DotfolderStack(
            name: "extrasdemo",
            workingDirectory: projectWorkingDirectory,
            defaultsDirectory: defaultsDirectory,
            userDirectory: userDirectory
        )
    }
}
