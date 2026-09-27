import FoundationModels
import FoundationModelsExtras
import Testing

/// Holds ``SubmissionBoundaryTool`` to the public surface.
///
/// The import is plain, with no `@testable`. When the protocol or its
/// requirement loses `public`, the conformer below does not compile. A
/// consumer in another package conforms in the same way.
@Suite("SubmissionBoundaryTool conformance over a plain import")
struct SubmissionBoundaryToolPublicSurfaceTests {
    /// The arguments of the two test tools.
    @Generable
    struct ProbeArguments {
        /// The value the model sends.
        let value: String
    }

    /// The model-facing name of the conforming tool.
    private static let conformerName = "conforming-boundary-probe"

    /// A tool that conforms to ``SubmissionBoundaryTool`` from outside the
    /// module. Its hook does nothing: this suite reads the conformance only.
    private struct ConformingTool: SubmissionBoundaryTool {
        let name = SubmissionBoundaryToolPublicSurfaceTests.conformerName
        let description = "test-only tool that conforms to SubmissionBoundaryTool"

        func submissionWillBegin() async {}

        func call(arguments: ProbeArguments) async throws -> String {
            arguments.value
        }
    }

    /// A tool with no ``SubmissionBoundaryTool`` conformance.
    private struct PlainTool: Tool {
        let name = "plain-tool"
        let description = "test-only tool with no submission-boundary conformance"

        func call(arguments: ProbeArguments) async throws -> String {
            arguments.value
        }
    }

    @Test("a cast of an `any Tool` to `any SubmissionBoundaryTool` finds a conformer and misses a plain tool")
    func theCastFindsOnlyAConformer() {
        let tools: [any Tool] = [PlainTool(), ConformingTool()]

        let conformers = tools.compactMap { $0 as? any SubmissionBoundaryTool }

        #expect(conformers.map(\.name) == [Self.conformerName])
    }
}
