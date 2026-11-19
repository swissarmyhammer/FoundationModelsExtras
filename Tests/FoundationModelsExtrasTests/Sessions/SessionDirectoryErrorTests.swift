import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// ``SessionDirectoryError`` names each failure of the directory.
@Suite("SessionDirectoryError: the failures of the directory")
struct SessionDirectoryErrorTests {
    /// The chain depth limit of the loop guards (ROUTER-5).
    private static let chainLimit = 3

    /// A length limit of a message, for the test.
    private static let lengthLimit = 4000

    /// A position before the start of a history, for the cut error.
    private static let positionBeforeHistory = -1

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
            .archivedSession(ULID()),
            .forkCutOutOfRange(.historyPosition(positionBeforeHistory)),
            .forkUnsupported,
            .importUnsupported,
        ])
    func eachErrorSurvivesARoundTrip(error: SessionDirectoryError) throws {
        #expect(try SessionFixtures.roundTrip(error) == error)
    }
}
