import Foundation
import FoundationModelsExtras

/// The demo `SlashCommandProviding` conformer `extras-demo commands` drives
/// (plan.md §7): a static `.prompt` command, a static `.action` command
/// that streams a few lines, and a single `commandUpdates` tick that
/// republishes the set with a third command added.
final class DemoCommandProvider: SlashCommandProviding, Sendable {
    /// `greetCommand`'s name, shared with `CommandsCommand` so the two files
    /// can't drift out of sync.
    static let greetCommandName = "greet"

    /// `streamCommand`'s name, shared with `CommandsCommand` so the two
    /// files can't drift out of sync.
    static let streamCommandName = "stream"

    /// The `.prompt` command: its template is rendered through the
    /// templating pillar before display, exactly as a harness would before
    /// folding it into a model turn.
    static let greetCommand = SlashCommand(
        name: greetCommandName,
        description: "Greets the caller by name (prompt command)",
        argumentHint: "<name>",
        body: .prompt(template: "Hello {{ name }}!")
    )

    /// The `.action` command: runs in-process, streams a few lines, never
    /// touches the model.
    static let streamCommand = SlashCommand(
        name: streamCommandName,
        description: "Streams a few lines (action command)",
        body: .action { invocation in
            AsyncThrowingStream { continuation in
                continuation.yield("line 1 for \(invocation.arguments)")
                continuation.yield("line 2 for \(invocation.arguments)")
                continuation.yield("line 3 for \(invocation.arguments)")
                continuation.finish()
            }
        }
    )

    /// The command `publishStatusCommandAdded` adds to the re-published set.
    static let statusCommand = SlashCommand(
        name: "status",
        description: "Added by the commandUpdates tick",
        body: .prompt(template: "status ok")
    )

    /// Pushed re-publications of this conformer's full command set.
    let commandUpdates: AsyncStream<[SlashCommand]>?

    /// This provider's single re-publication tick's continuation.
    private let updatesContinuation: AsyncStream<[SlashCommand]>.Continuation

    /// Creates a provider with an unconsumed `commandUpdates` stream.
    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: [SlashCommand].self)
        commandUpdates = stream
        updatesContinuation = continuation
    }

    /// This conformer's static command set: `greetCommand` and
    /// `streamCommand`. Ignores `workingDirectory` — the demo's commands
    /// carry no file-backed state.
    func commands(workingDirectory: URL) async -> [SlashCommand] {
        [Self.greetCommand, Self.streamCommand]
    }

    /// Republishes the full command set with `statusCommand` added, then
    /// finishes the stream — this provider's single `commandUpdates` tick.
    func publishStatusCommandAdded() {
        updatesContinuation.yield([Self.greetCommand, Self.streamCommand, Self.statusCommand])
        updatesContinuation.finish()
    }
}
