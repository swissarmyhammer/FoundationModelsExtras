import Foundation
@testable import FoundationModelsExtras
import Testing
import ULID

/// ``SessionDirectoryError`` names each failure of the directory.
@Suite("SessionDirectoryError: the failures of the directory")
struct SessionDirectoryErrorTests {
    /// The chain depth limit of the loop guards (ROUTER-5).
    private static let chainLimit = 3

    /// A length limit of a message, for the test.
    private static let lengthLimit = 4000

    @Test(
        "each error survives a JSON round trip",
        arguments: [
            SessionDirectoryError.unknownSession(ULID()),
            .unknownAgent("reviwer", nearNames: ["reviewer", "writer"]),
            .unknownAgent("x", nearNames: []),
            .notADirectory(SessionFixtures.folder),
            .chainTooDeep(limit: chainLimit),
            .messageTooLong(limit: lengthLimit),
            .invalidTag("two words"),
            .noLauncher,
        ])
    func eachErrorSurvivesARoundTrip(error: SessionDirectoryError) throws {
        #expect(try SessionFixtures.roundTrip(error) == error)
    }
}
