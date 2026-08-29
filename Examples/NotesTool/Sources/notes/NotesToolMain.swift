import ArgumentParser
import Foundation
import NotesToolCore
import Operations
import OperationsCLI

/// The `notes` executable's entry point: plan.md's task 7 worked example of
/// the full stack, in two modes.
///
/// - Default: `notes note add --title …` — an `OperationCLIDriver` over
///   `NotesTool.make()`.
/// - `--chat`: registers the same tool on a `LanguageModelSession` and runs
///   `ChatValidationHarness`'s scripted, manual-run live-model validation
///   (guarded by `SystemLanguageModel` availability; degrades gracefully
///   off-device).
@main
internal enum NotesToolMain {
    /// The `--chat` flag that switches into live-model validation mode.
    private static let chatFlag = "--chat"

    /// Dispatches to `--chat` mode or the default CLI mode, based on
    /// `CommandLine.arguments`.
    internal static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == chatFlag {
            await ChatValidationHarness.run()
            return
        }
        await runCLI(arguments: arguments)
    }

    /// Drives `arguments` through an `OperationCLIDriver` over
    /// `NotesTool.make()`, printing its output and exiting with its code.
    ///
    /// - Parameter arguments: The command's arguments, excluding the
    ///   executable name.
    private static func runCLI(arguments: [String]) async {
        do {
            let driver = try OperationCLIDriver(tool: try NotesTool.make(), executableName: NotesTool.name)
            let result = await driver.run(arguments: arguments)
            if !result.output.isEmpty {
                print(result.output)
            }
            if result.exitCode != 0 {
                exit(result.exitCode)
            }
        } catch {
            FileHandle.standardError.write(Data("notes: \(error)\n".utf8))
            exit(1)
        }
    }
}
