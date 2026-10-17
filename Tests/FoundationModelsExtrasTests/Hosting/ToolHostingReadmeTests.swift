import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

// README example: begin (the tool)

/// Runs the tests in the background. A call waits for the settle period of
/// the site. A run that ends in that time answers with its own result. A
/// longer run answers with a pending envelope, and the session injects the
/// result into the conversation as a new message when the run finishes.
private struct RunTests: Tool, BackgroundTool {
    let name = "run_tests"
    let description = "Runs the tests of the package."

    @Generable
    struct Arguments {
        let filter: String
    }

    var mount: ToolMount? { ToolMount(mode: .background) }

    func call(arguments: Arguments) async throws -> String {
        await ToolContext.current?.progress("running \(arguments.filter)")
        return "all tests pass"
    }
}

// README example: end (the tool)

/// Keeps the "Tool hosting" example of `README.md` correct. The tool and the
/// mount code are the same as in the README. The test calls the mounted tool
/// as the model does, then collects the result from the run plane as the host
/// does.
@Suite("Tool hosting: the README example")
struct ToolHostingReadmeTests {
    /// A sink that drops each event.
    private struct DroppingSink: OperationEventSink {
        func post(event: OperationEvent) async {}
    }

    @Test("the README example mounts a background tool: a short run answers with its own result, and the host collects the same result from the run plane")
    func readmeBackgroundToolExample() async throws {
        let sink = DroppingSink()

        // README example: begin (the host)
        // The host mounts each tool on the run plane of its session. `sink`
        // gets each event of each run. `inlineSettleGrace` is how long a
        // background call waits for its run before it answers with a pending
        // envelope. The default is `ToolMount.defaultInlineSettleGrace`.
        let runPlane = RunPlane()
        let site = MountSite(
            sessionID: ULID(), runPlane: runPlane, sink: sink, inlineSettleGrace: ToolMount.defaultInlineSettleGrace)
        func mounted(_ tool: any Tool) -> any Tool {
            ToolFailureDelivery.makeWrapped(
                tool: ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous))
        }
        let tools = [mounted(RunTests())]
        // Give `tools` to the model session: `LanguageModelSession(tools: tools)`.
        // When a run continues, the session injects its result into the
        // conversation as a new message, so the model calls no tool to wait.
        // The host can read the result from the run plane with
        // `runPlane.wait(completionToken:seconds:)`.
        // README example: end (the host)

        // The model calls `run_tests`. The run ends inside the default settle
        // period, so the call answers with the result, and no envelope.
        let runTests = try #require(tools.first as? any Tool<RunTests.Arguments, String>)
        let rendered = try await runTests.call(arguments: RunTests.Arguments(filter: "Hosting"))
        // The run plane still holds the result, and the host collects it.
        let token = try #require(await runPlane.settledRunTokens().first)
        let outcome = await runPlane.wait(completionToken: token, seconds: nil)

        // README example: begin (the end of the session)
        // At the end of the session, the sweep stops each run that is still open.
        let swept = await runPlane.sweep()
        // README example: end (the end of the session)

        #expect(rendered == "all tests pass")
        #expect(PendingRunEnvelope.makeDecoded(fromRendered: rendered) == nil)
        #expect(outcome.settledTerminal?.detail == "all tests pass")
        #expect(swept.isEmpty)
    }
}
