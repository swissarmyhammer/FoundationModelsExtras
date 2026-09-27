@testable import FoundationModelsExtras
import FoundationModels
import Testing

/// A decorator passes ``SubmissionBoundaryTool/submissionWillBegin()`` to the
/// tool that it wraps, so a host that casts the mounted tool still reaches
/// the tool that the caller registered.
@Suite("SubmissionBoundaryTool: a decorator passes the boundary to the tool beneath")
struct SubmissionBoundaryToolTests {
    /// How many boundaries the test sends.
    private static let boundaryCount = 2

    /// Counts the hook calls of one tool.
    private actor HookCounter {
        /// How many times the hook was called.
        private(set) var count = 0

        /// Adds one hook call.
        func increment() {
            count += 1
        }
    }

    /// The arguments of the test tool.
    @Generable
    struct ProbeArguments {
        /// The value the model sends.
        let value: String
    }

    /// A tool that counts each hook call.
    private struct CountingTool: SubmissionBoundaryTool {
        let name = "counting-boundary-probe"
        let description = "test-only tool that counts each submissionWillBegin() call"

        /// The counter the test reads.
        let counter: HookCounter

        func submissionWillBegin() async {
            await counter.increment()
        }

        func call(arguments: ProbeArguments) async throws -> String {
            arguments.value
        }
    }

    @Test("two decorators, one on the other, pass each boundary to the conformer beneath")
    func theChainPassesTheBoundary() async throws {
        let counter = HookCounter()
        let once = ToolFailureDelivery.makeWrapped(tool: CountingTool(counter: counter))
        let twice = ToolFailureDelivery.makeWrapped(tool: once)
        let boundary = try #require(twice as? any SubmissionBoundaryTool)

        for _ in 0..<Self.boundaryCount {
            await boundary.submissionWillBegin()
        }

        #expect(await counter.count == Self.boundaryCount)
    }
}
