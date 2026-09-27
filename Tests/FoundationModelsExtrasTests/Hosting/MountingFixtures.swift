@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// The arguments of the ambient fixture tools: one string that the tool posts
/// as the detail of its event.
@Generable
struct AmbientToolArguments {
    /// The detail that the tool posts.
    let value: String
}

/// An output that is not `String`. A tool with this output gets only a bound
/// context, not a runner.
struct NonStringToolOutput: PromptRepresentable, Sendable {
    /// The text of the output.
    let text: String

    /// The text as a plain `Prompt`.
    var promptRepresentation: Prompt { Prompt(text) }
}

/// Posts one `.completed` event with `value` through the bound context, then
/// returns the completion token of that context, or `"unbound"`.
struct AmbientNonStringOutputTool: Tool {
    let name = "ambient-non-string"
    let description = "test-only non-String-output tool that posts through the ambient ToolContext"

    func call(arguments: AmbientToolArguments) async throws -> NonStringToolOutput {
        await ToolContext.current?.post(
            OperationEvent(
                tool: "ambient-fixture", op: "run thing", correlationID: "restamped-by-context",
                kind: .completed, detail: arguments.value))
        return NonStringToolOutput(text: ToolContext.current?.completionToken ?? "unbound")
    }
}

/// The fixtures of the mount suites that the runner suites do not use.
extension MountFixtures {
    /// Sleeps for `duration` seconds, posts no progress, then returns.
    struct QuietTool: Tool {
        let name = "quiet_tool"
        let description = "runs for a time with no progress, then returns"
        let duration: TimeInterval

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(for: .seconds(duration))
            return "quiet: \(arguments.value)"
        }
    }

    /// Waits on its gate, and declares ``ToolMount/synchronous``.
    struct DeclaredRunToCompletionRunner: Tool, BackgroundTool {
        let name = "declared_run_to_completion_tool"
        let description = "declares the mount it cannot work without"
        let gate: RunLatch

        var mount: ToolMount? { .synchronous }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "declared: \(arguments.value)"
        }
    }

    /// Waits on its gate, and declares background with no timeout.
    struct DeclaredBackgroundToolRunner: Tool, BackgroundTool {
        let name = "declared_background_tool"
        let description = "declares background and is handed back as a token at once"
        let gate: RunLatch

        var mount: ToolMount? { ToolMount(mode: .background, timeout: nil) }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "background: \(arguments.value)"
        }
    }

    /// Returns at once, and keeps its schema out of the instructions. A
    /// forwarder that gives the default of `Tool` does not agree with it.
    struct SchemaOmittingTool: Tool {
        let name = "schema_omitting_tool"
        let description = "returns immediately and keeps its schema out of the instructions"

        var includesSchemaInInstructions: Bool { false }

        func call(arguments: MountArguments) async throws -> String {
            "schema omitted: \(arguments.value)"
        }
    }

    /// Returns a text that is not `String` output, and posts nothing.
    struct NonStringOutputTool: Tool {
        let name = "non_string_output_tool"
        let description = "returns a non-String PromptRepresentable"

        func call(arguments: MountArguments) async throws -> NonStringToolOutput {
            NonStringToolOutput(text: "ignored")
        }
    }

    /// Waits on its gate, then returns the session of the bound context.
    struct GatedSessionIdentityTool: Tool {
        let name = "gated_session_identity_tool"
        let description = "returns the ambient context's session identity once its gate opens"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return ToolContext.current?.sessionID.ulidString ?? "unbound"
        }
    }

    /// Mounts ``AttachingTool`` on the context of its own run, and calls it
    /// in band. It attaches nothing itself.
    struct NestingAttachingTool: Tool {
        let name = "nesting_attaching_tool"
        let description = "mounts the attaching tool on its own context and calls it in band"

        func call(arguments: MountArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await context.mount(AttachingTool()).call(arguments: arguments)
        }
    }

    /// Attaches both records, then returns a text that is not `String`
    /// output.
    struct AttachingNonStringOutputTool: Tool {
        let name = "attaching_non_string_output_tool"
        let description = "attaches two records then returns a non-String output"

        func call(arguments: MountArguments) async throws -> NonStringToolOutput {
            attachInCallOrder()
            return NonStringToolOutput(text: "attached: \(arguments.value)")
        }
    }

    /// Attaches ``firstAttachment`` and then ``secondAttachment`` to the bound
    /// context. Does nothing when no context is bound.
    static func attachInCallOrder() {
        ToolContext.current?.attach(firstAttachment)
        ToolContext.current?.attach(secondAttachment)
    }
}
