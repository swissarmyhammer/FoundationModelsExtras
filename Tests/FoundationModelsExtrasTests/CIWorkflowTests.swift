import FixtureSupport
import Foundation
import Testing

/// Pins the inputs that `.github/workflows/ci.yml` gives to the shared
/// `swift-ci.yaml` workflow.
///
/// The root manifest never names the nested `IntegrationTests/` package, so
/// the root build does not compile it. `integration-package-path` makes the
/// unit job build that package on each run, and makes the integration job run
/// it. `integration-metallib-glob` puts the MLX shader library beside each
/// test bundle before the run. If a later edit removes one of these lines,
/// this suite fails.
@Suite("CI workflow")
struct CIWorkflowTests {
    /// The workflow, relative to the package root.
    private static let workflowPath = ".github/workflows/ci.yml"

    /// The lines that the workflow must hold, with no indentation.
    static let requiredLines = [
        "uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main",
        "integration-package-path: IntegrationTests",
        #"integration-metallib-glob: "*Cmlx*/default.metallib""#,
    ]

    @Test("ci.yml holds each required line", arguments: requiredLines)
    func holdsTheLine(_ line: String) throws {
        let workflow = try FixtureFile.text(Self.workflowPath).get()
        let lines = workflow.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        #expect(lines.contains(line), "ci.yml must hold the line \(line)")
    }
}
