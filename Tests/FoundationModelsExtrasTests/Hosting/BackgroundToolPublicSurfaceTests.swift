import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

/// Holds ``BackgroundTool`` and ``ToolMount`` to the public surface.
///
/// The import is plain, with no `@testable`. When a member loses `public`,
/// this file does not compile.
@Suite("BackgroundTool and ToolMount over a plain import")
struct BackgroundToolPublicSurfaceTests {
    /// The timeout of the test mount, in seconds.
    private static let timeoutSeconds: TimeInterval = 30

    /// The arguments of the test tool.
    @Generable
    struct ProbeArguments {
        /// The value the model sends.
        let value: String
    }

    /// A background tool that declares nothing, so it gets each default.
    private struct DefaultBackgroundTool: Tool, BackgroundTool {
        let name = "default-background"
        let description = "test-only background tool with no declarations"

        func call(arguments: ProbeArguments) async throws -> String {
            arguments.value
        }
    }

    @Test("a background tool that declares nothing gets each default")
    func aToolThatDeclaresNothingGetsTheDefaults() {
        let tool = DefaultBackgroundTool()
        let completionToken = ULID().ulidString

        #expect(tool.mount == nil)
        // Outside a mount site, the grace is the one default constant.
        #expect(tool.inlineSettleGrace == ToolMount.defaultInlineSettleGrace)
        #expect(tool.timeout(from: GeneratedContent(properties: [:])) == nil)
        #expect(tool.runKind == .swiftTask)
        #expect(tool.canceler(forCompletionToken: completionToken) == nil)
        #expect(
            tool.collectInstruction(forCompletionToken: completionToken)
                == PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken))
    }

    @Test("the default settle period is 6 seconds")
    func theDefaultSettlePeriodIsSixSeconds() {
        #expect(ToolMount.defaultInlineSettleGrace == 6)
    }

    @Test("the synchronous mount runs to completion with no timeout")
    func theSynchronousMountHasNoTimeout() {
        #expect(ToolMount.synchronous == ToolMount(mode: .runToCompletion))
        #expect(ToolMount.synchronous.timeout == nil)
    }

    @Test("a background mount keeps its timeout")
    func aBackgroundMountKeepsItsTimeout() {
        let mount = ToolMount(mode: .background, timeout: Self.timeoutSeconds)

        #expect(mount.mode == .background)
        #expect(mount.timeout == Self.timeoutSeconds)
    }

    @Test("a timeout failure names the tool and the seconds")
    func aTimeoutFailureNamesTheToolAndTheSeconds() {
        let failure = ToolMountError.timedOut(tool: "shell", timeoutSeconds: Self.timeoutSeconds)

        #expect(failure.description == "shell timed out after 30.0 seconds with no progress")
    }
}
