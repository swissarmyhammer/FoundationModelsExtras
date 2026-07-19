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
