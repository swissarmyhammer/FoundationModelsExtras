import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `SlashCommand` and `SlashCommandProviding`: the
/// static and streaming provider shapes conformers use to contribute
/// commands to a harness session (plan.md §2).
@Suite struct SlashCommandTests {
    /// A conformer with a fixed set of commands and no `commandUpdates`
    /// re-publication — the static provider shape.
    struct StaticFakeProvider: SlashCommandProviding {
        let fixedCommands: [SlashCommand]

        func commands(workingDirectory: URL) async -> [SlashCommand] {
            fixedCommands
        }

        var commandUpdates: AsyncStream<[SlashCommand]>? { nil }
    }

    @Test func staticProviderReturnsItsCommandsAndHasNoCommandUpdates() async {
        let command = SlashCommand(
            name: "help", description: "Shows help", argumentHint: nil,
            body: .prompt(template: "Explain the available commands."))
        let provider = StaticFakeProvider(fixedCommands: [command])

        let commands = await provider.commands(workingDirectory: URL(fileURLWithPath: "/tmp"))

        #expect(commands.map(\.name) == ["help"])
        #expect(provider.commandUpdates == nil)
    }

    @Test func promptBodyRoundTripsItsTemplateString() {
        let command = SlashCommand(
            name: "ps", description: "List processes", argumentHint: "<pid>",
            body: .prompt(template: "List process {{ arguments }}"))

        guard case .prompt(let template) = command.body else {
            Issue.record("expected a .prompt body")
            return
        }
        #expect(template == "List process {{ arguments }}")
    }

    @Test func actionBodyStreamsMultipleChunksCollectedViaForTryAwait() async throws {
        let command = SlashCommand(
            name: "stream", description: "Streams output", argumentHint: nil,
            body: .action { invocation in
                AsyncThrowingStream { continuation in
                    continuation.yield("chunk1 \(invocation.arguments)")
                    continuation.yield("chunk2")
                    continuation.finish()
                }
            })

        guard case .action(let makeStream) = command.body else {
            Issue.record("expected an .action body")
            return
        }
        let invocation = SlashCommand.Invocation(
            arguments: "42", workingDirectory: URL(fileURLWithPath: "/tmp"))

        var chunks: [String] = []
        for try await chunk in makeStream(invocation) {
            chunks.append(chunk)
        }

        #expect(chunks == ["chunk1 42", "chunk2"])
    }

    @Test func actionBodyThrowingErrorSurfacesToTheCaller() async {
        struct SampleError: Error, Equatable {}
        let command = SlashCommand(
            name: "fail", description: "Always fails", argumentHint: nil,
            body: .action { _ in
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: SampleError())
                }
            })

        guard case .action(let makeStream) = command.body else {
            Issue.record("expected an .action body")
            return
        }
        let invocation = SlashCommand.Invocation(
            arguments: "", workingDirectory: URL(fileURLWithPath: "/tmp"))

        await #expect(throws: SampleError.self) {
            for try await _ in makeStream(invocation) {}
        }
    }

    /// A conformer whose command set changes mid-session, re-published
    /// through `commandUpdates` — the dynamic provider shape.
    final class DynamicFakeProvider: SlashCommandProviding, @unchecked Sendable {
        private let continuation: AsyncStream<[SlashCommand]>.Continuation
        let commandUpdates: AsyncStream<[SlashCommand]>?

        init() {
            var capturedContinuation: AsyncStream<[SlashCommand]>.Continuation!
            let stream = AsyncStream<[SlashCommand]> { capturedContinuation = $0 }
            self.continuation = capturedContinuation
            self.commandUpdates = stream
        }

        func commands(workingDirectory: URL) async -> [SlashCommand] {
            []
        }

        func publish(_ commands: [SlashCommand]) {
            continuation.yield(commands)
        }
    }

    @Test func dynamicProviderTicksCommandUpdatesWithTheRepublishedSet() async {
        let provider = DynamicFakeProvider()
        let updated = SlashCommand(
            name: "new", description: "A newly added command", argumentHint: nil,
            body: .prompt(template: "..."))

        guard let updates = provider.commandUpdates else {
            Issue.record("expected commandUpdates to be non-nil for a dynamic provider")
            return
        }
        var iterator = updates.makeAsyncIterator()
        provider.publish([updated])

        let received = await iterator.next()

        #expect(received?.map(\.name) == ["new"])
    }
}
