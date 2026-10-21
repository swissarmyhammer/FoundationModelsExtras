import FixtureSupport
import Foundation
import Testing

/// The session directory port has no Router concept and no ACP concept, thus
/// its folder imports only Foundation and ULID.
@Suite("Sessions sources: the port imports no Router and no ACP module")
struct SessionsSourceBoundaryTests {
    /// The folder of the port, relative to the package root.
    private static let sessionsFolder = "Sources/FoundationModelsExtras/Sessions"

    /// The modules that a file of the port may import.
    private static let allowedImports: Set<String> = ["import Foundation", "import ULID"]

    @Test("each file of the port imports only Foundation and ULID")
    func eachFileImportsOnlyFoundationAndULID() throws {
        let sources = try FixtureFile.swiftSources(under: Self.sessionsFolder)
        let forbiddenImports = sources.flatMap { source in
            source.text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") && !Self.allowedImports.contains($0) }
                .map { "\(source.name): \($0)" }
        }

        #expect(!sources.isEmpty)
        #expect(forbiddenImports == [])
    }
}
