import Foundation
import Testing
import ULID

@testable import FoundationModelsExtras

/// A session can have a recap: one sentence about what it did and where it
/// stands now. ``InMemorySessionDirectory/setRecap(of:_:at:)`` sets it.
@Suite("In-memory session directory: the recap of a session")
struct InMemorySessionDirectoryRecapTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// The recap that the tests set.
    private static let recap = "Fixed the parser tests; the build is green and the PR waits for review."

    /// The time of the recap that the tests set.
    private static let recapAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a summary made with no recap has no recap and no recap time")
    func aSummaryWithNoRecapHasNone() {
        let summary = SessionFixtures.summary()

        #expect(summary.recap == nil)
        #expect(summary.recapAt == nil)
    }

    @Test("setRecap sets the recap, sends one factsChanged with it, and a query gives it")
    func setRecapSetsTheRecap() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        let stream = directory.events()

        try directory.setRecap(of: id, Self.recap, at: Self.recapAt)
        let events = await Fixtures.drain(stream, of: directory)
        let summary = try #require(try await directory.summary(of: id))

        #expect(summary.recap == Self.recap)
        #expect(summary.recapAt == Self.recapAt)
        #expect(events == [.factsChanged(summary)])
    }

    @Test("the same recap a second time sends no event")
    func theSameRecapSendsNoEvent() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        try directory.setRecap(of: id, Self.recap, at: Self.recapAt)
        let stream = directory.events()

        try directory.setRecap(of: id, Self.recap, at: Self.recapAt)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(events.isEmpty)
    }

    @Test("an archive and an unarchive keep the recap")
    func anArchiveKeepsTheRecap() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        try directory.setRecap(of: id, Self.recap, at: Self.recapAt)

        let archived = try await directory.archive(id, by: Fixtures.user)
        let unarchived = try await directory.unarchive(id, by: Fixtures.user)

        #expect(archived.recap == Self.recap)
        #expect(unarchived.recap == Self.recap)
        #expect(unarchived.recapAt == Self.recapAt)
    }

    @Test("setRecap of an unknown session throws unknownSession")
    func setRecapOfAnUnknownSessionThrows() {
        let directory = Fixtures.makeDirectory()
        let id = ULID()

        #expect(throws: SessionDirectoryError.unknownSession(id)) {
            try directory.setRecap(of: id, Self.recap, at: Self.recapAt)
        }
    }

    @Test("a summary from JSON with no recap keys has no recap")
    func aSummaryWithNoRecapKeysDecodes() throws {
        var summary = SessionFixtures.summary()
        summary.recap = Self.recap
        summary.recapAt = Self.recapAt

        let withoutRecap = try SessionFixtures.decodeWithout(key: "recap", from: summary)
        let withoutTime = try SessionFixtures.decodeWithout(key: "recapAt", from: summary)

        #expect(withoutRecap.recap == nil)
        #expect(withoutTime.recapAt == nil)
    }
}
