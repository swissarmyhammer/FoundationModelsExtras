import ArgumentParser
import Foundation
import FoundationModelsExtras

/// `extras-demo commands` — pillar 1 (plan.md §7): registers a demo
/// `SlashCommandProviding` with one `.prompt` command (rendered through the
/// templating pillar before display) and one `.action` command (streams a
/// few lines), invokes both, then ticks `commandUpdates` and prints the
/// re-published set — the exact consumption pattern the harness's command
/// registry uses.
struct CommandsCommand: AsyncParsableCommand {
    /// This subcommand's command-line configuration.
    static let configuration = CommandConfiguration(
        commandName: "commands",
        abstract: "Registers a demo SlashCommandProviding, runs its prompt and action commands, then ticks commandUpdates."
    )

    /// Invokes `DemoCommandProvider`'s `.prompt` and `.action` commands,
    /// then ticks its `commandUpdates` and prints the re-published set.
    func run() async throws {
        let provider = DemoCommandProvider()
        let workingDirectory = DemoFixtures.projectWorkingDirectory
        let initial = await provider.commands(workingDirectory: workingDirectory)

        guard let greet = initial.first(where: { $0.name == "greet" }),
            case .prompt(let template) = greet.body
        else {
            throw ExitCode.failure
        }
        var context = TemplateContext()
        context.set(key: "name", to: .string("World"))
        let rendered = try TemplateEngine(partials: nil).render(template, context: context, trust: .untrusted)
        print("prompt 'greet' rendered: \(rendered)")

        guard let stream = initial.first(where: { $0.name == "stream" }),
            case .action(let makeStream) = stream.body
        else {
            throw ExitCode.failure
        }
        let invocation = SlashCommand.Invocation(arguments: "demo-arg", workingDirectory: workingDirectory)
        for try await line in makeStream(invocation) {
            print("action 'stream' line: \(line)")
        }

        provider.publishStatusCommandAdded()
        if let updates = provider.commandUpdates {
            for await updated in updates {
                print("commandUpdates republished: \(updated.map(\.name).joined(separator: ", "))")
            }
        }
    }
}
