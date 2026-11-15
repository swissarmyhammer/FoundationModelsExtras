import Foundation
@testable import FoundationModelsExtras
import Synchronization
import Testing
import ULID

/// The pin and the last use of a session in ``InMemorySessionDirectory``:
/// ``SessionDirectory/setPinned(_:of:)``, ``SessionDirectory/markUsed(_:)``,
/// the ``SessionQuery/pinned`` filter and the ``SessionOrder`` of a query.
@Suite("In-memory session directory: pin and last use")
struct InMemorySessionDirectoryPinTests {
    private typealias Fixtures = InMemorySessionDirectoryFixtures

    /// A clock that gives a time one second later at each read, thus each
    /// change of a test gets its own time.
    private final class TickingClock: Sendable {
        /// The number of reads.
        private let reads = Mutex(0)

        /// The next time: one second after the time before.
        func next() -> Date {
            let count = reads.withLock { reads in
                reads += 1
                return reads
            }
            return Fixtures.now.addingTimeInterval(TimeInterval(count))
        }
    }

    /// Makes a directory with the fake launcher and a ticking clock.
    ///
    /// - Returns: A new, empty directory.
    private static func makeTickingDirectory() -> InMemorySessionDirectory {
        let clock = TickingClock()
        return InMemorySessionDirectory(launcher: Fixtures.launcher, now: { clock.next() })
    }

    /// Starts `count` idle sessions.
    ///
    /// - Parameters:
    ///   - count: The number of sessions.
    ///   - directory: The directory to start them in.
    /// - Returns: The ids, the first start first.
    private static func startSessions(_ count: Int, in directory: InMemorySessionDirectory) async throws -> [ULID] {
        try await (0..<count).asyncMap { _ in try await Fixtures.startIdleSession(in: directory) }
    }

    @Test("a pin sets the pin time and sends factsChanged")
    func aPinSetsThePinTime() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        let stream = directory.events()

        let pinned = try await directory.setPinned(true, of: id)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(pinned.isPinned)
        #expect(pinned.pinnedAt == Fixtures.now)
        #expect(events == [.factsChanged(pinned)])
        #expect(try await directory.summary(of: id) == pinned)
    }

    @Test("a second pin keeps the first pin time and sends no event")
    func aSecondPinKeepsTheFirstTime() async throws {
        let directory = Self.makeTickingDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        let first = try await directory.setPinned(true, of: id)
        let stream = directory.events()

        let second = try await directory.setPinned(true, of: id)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(second.pinnedAt == first.pinnedAt)
        #expect(events.isEmpty)
    }

    @Test("an unpin clears the pin time and sends factsChanged")
    func anUnpinClearsThePinTime() async throws {
        let directory = Fixtures.makeDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        _ = try await directory.setPinned(true, of: id)
        let stream = directory.events()

        let unpinned = try await directory.setPinned(false, of: id)
        let events = await Fixtures.drain(stream, of: directory)

        #expect(!unpinned.isPinned)
        #expect(unpinned.pinnedAt == nil)
        #expect(events == [.factsChanged(unpinned)])
    }

    @Test("a use sets the time of the last use and sends factsChanged")
    func aUseSetsTheLastUseTime() async throws {
        let directory = Self.makeTickingDirectory()
        let id = try await Fixtures.startIdleSession(in: directory)
        let first = try await directory.markUsed(id)
        let stream = directory.events()

        let second = try await directory.markUsed(id)
        let events = await Fixtures.drain(stream, of: directory)

        let firstUse = try #require(first.lastUsedAt)
        let secondUse = try #require(second.lastUsedAt)
        #expect(secondUse > firstUse)
        #expect(events == [.factsChanged(second)])
    }

    @Test("a pin or a use of an unknown session throws unknownSession")
    func anUnknownSessionThrows() async throws {
        let directory = Fixtures.makeDirectory()
        let id = ULID()

        await #expect(throws: SessionDirectoryError.unknownSession(id)) {
            try await directory.setPinned(true, of: id)
        }
        await #expect(throws: SessionDirectoryError.unknownSession(id)) {
            try await directory.markUsed(id)
        }
    }

    @Test("the pinned filter gives only the pinned or only the sessions that are not pinned")
    func thePinnedFilter() async throws {
        let directory = Fixtures.makeDirectory()
        let ids = try await Self.startSessions(3, in: directory)
        _ = try await directory.setPinned(true, of: ids[1])

        let pinned = try await directory.sessions(matching: SessionQuery(pinned: true))
        let notPinned = try await directory.sessions(matching: SessionQuery(pinned: false))

        #expect(pinned.map(\.id) == [ids[1]])
        #expect(notPinned.map(\.id) == [ids[2], ids[0]])
    }

    @Test("the pin order gives the first pin first, then the sessions that are not pinned")
    func thePinOrder() async throws {
        let directory = Self.makeTickingDirectory()
        let ids = try await Self.startSessions(4, in: directory)
        _ = try await directory.setPinned(true, of: ids[2])
        _ = try await directory.setPinned(true, of: ids[0])
        _ = try await directory.setPinned(true, of: ids[2])

        let ordered = try await directory.sessions(matching: SessionQuery(order: .pinOrder))

        #expect(ordered.map(\.id) == [ids[2], ids[0], ids[3], ids[1]])
    }

    @Test("the last-use order gives the newest use first, then the sessions that no client used")
    func theLastUseOrder() async throws {
        let directory = Self.makeTickingDirectory()
        let ids = try await Self.startSessions(4, in: directory)
        _ = try await directory.markUsed(ids[1])
        _ = try await directory.markUsed(ids[0])
        _ = try await directory.markUsed(ids[2])
        _ = try await directory.markUsed(ids[1])

        let ordered = try await directory.sessions(matching: SessionQuery(order: .lastUsedFirst))

        #expect(ordered.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
    }

    @Test("the limit applies after the order, and the filter and the order combine")
    func theLimitAppliesAfterTheOrder() async throws {
        let directory = Self.makeTickingDirectory()
        let ids = try await Self.startSessions(4, in: directory)
        _ = try await directory.markUsed(ids[0])
        _ = try await directory.markUsed(ids[3])
        _ = try await directory.markUsed(ids[1])
        _ = try await directory.setPinned(true, of: ids[1])

        let recent = try await directory.sessions(
            matching: SessionQuery(pinned: false, order: .lastUsedFirst, limit: 2))

        #expect(recent.map(\.id) == [ids[3], ids[0]])
    }

    @Test("a registered summary keeps the pin time and the time of the last use of the test")
    func aRegisteredSummaryKeepsItsTimes() async throws {
        let directory = Fixtures.makeDirectory()
        let summary = SessionFixtures.summary()

        directory.register(summary)
        let stored = try #require(try await directory.summary(of: summary.id))

        #expect(stored.pinnedAt == summary.pinnedAt)
        #expect(stored.lastUsedAt == summary.lastUsedAt)
    }
}
