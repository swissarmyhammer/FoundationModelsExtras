import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

// README example: begin (the two tools)

/// Runs the tests in the background. A call waits for the settle period of
/// the site. A run that ends in that time answers with its own result. A
/// longer run answers with a pending envelope, and the model collects the
/// result later.
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

/// Waits for a background run, with the completion token of its envelope.
private struct Wait: Tool {
    static let waitSeconds: Double = 30

    let name = "wait"
    let description = "Waits for a background run."

    @Generable
    struct Arguments {
        let completionToken: String
    }

    func call(arguments: Arguments) async throws -> String {
        let outcome = await ToolContext.current?.wait(completionToken: arguments.completionToken, seconds: Self.waitSeconds)
        guard case .settled(let terminal) = outcome else { return "The run continues." }
        return terminal.detail
    }
}

// README example: end (the two tools)

/// Keeps the "Tool hosting" example of `README.md` correct. The tools and the
/// mount code are the same as in the README. The test calls the mounted tools
/// as the model does.
@Suite("Tool hosting: the README example", .timeLimit(.minutes(1)))
struct ToolHostingReadmeTests {
    /// A sink that drops each event.
    private struct DroppingSink: OperationEventSink {
        func post(event: OperationEvent) async {}
    }

    @Test("the README example mounts a background tool: a short run answers with its own result, and the wait tool collects the same result")
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
        let tools = [mounted(RunTests()), mounted(Wait())]
        // Give `tools` to the model session: `LanguageModelSession(tools: tools)`.
        // README example: end (the host)

        // The model calls `run_tests`. The run ends inside the default settle
        // period, so the call answers with the result, and no envelope.
        let runTests = try #require(tools.first as? any Tool<RunTests.Arguments, String>)
        let wait = try #require(tools.last as? any Tool<Wait.Arguments, String>)
        let rendered = try await runTests.call(arguments: RunTests.Arguments(filter: "Hosting"))
        // The run plane still holds the result, and `wait` collects it.
        let token = try #require(await runPlane.settledRunTokens().first)
        let result = try await wait.call(arguments: Wait.Arguments(completionToken: token))

        // README example: begin (the end of the session)
        // At the end of the session, the sweep stops each run that is still open.
        let swept = await runPlane.sweep()
        // README example: end (the end of the session)

        #expect(rendered == "all tests pass")
        #expect(PendingRunEnvelope.makeDecoded(fromRendered: rendered) == nil)
        #expect(result == "all tests pass")
        #expect(swept.isEmpty)
    }
}
