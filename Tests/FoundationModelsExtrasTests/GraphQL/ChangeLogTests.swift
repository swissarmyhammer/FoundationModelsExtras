import Foundation
import Testing

@testable import FoundationModelsExtras

/// Proves the change log of a `changes` subscription: the cursors, the replay and the live events, the filter of
/// each subscriber, and each case that ends a subscription with `RESYNC_REQUIRED`.
@Suite("ChangeLog")
struct ChangeLogTests {
    /// The buffer size of the small logs of these tests.
    static let smallCapacity = 2

    /// A sequence number that no log of these tests reaches.
    static let unreachedSequence: UInt64 = 99

    /// The code of the error that ends a subscription that cannot resume.
    static let resyncCode = "RESYNC_REQUIRED"

    /// Reads as many entries from a stream as `expected` holds.
    ///
    /// - Parameters:
    ///   - expected: The events that the test expects, which give the number of entries to read.
    ///   - stream: The stream.
    /// - Returns: The events of the entries, in order.
    /// - Throws: The error that ends the stream before it gives that many entries.
    static func events(
        like expected: [String],
        of stream: AsyncThrowingStream<ChangeLogEntry<String>, Error>
    ) async throws -> [String] {
        var events: [String] = []
        for try await entry in stream {
            events.append(entry.event)
            if events.count == expected.count {
                break
            }
        }
        return events
    }

    /// Reads a stream to its end, and gives the error that ended it.
    ///
    /// - Parameter stream: The stream.
    /// - Returns: The toolkit error that ended the stream, or `nil` when the stream ended with no toolkit error.
    static func endingError(
        of stream: AsyncThrowingStream<ChangeLogEntry<String>, Error>
    ) async -> GraphQLToolkitError? {
        await #expect(throws: GraphQLToolkitError.self) {
            for try await _ in stream {}
        }
    }

    // MARK: - Cursors

    @Test("append gives strictly increasing cursors, and cursor is the newest")
    func appendGivesIncreasingCursors() async throws {
        let log = ChangeLog<String>()
        let start = await log.cursor

        let first = await log.append("a")
        let second = await log.append("b")

        let sequences = try [start, first.cursor, second.cursor].map { cursor in
            try #require(ChangeLogCursor(parsing: cursor)).sequence
        }
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == sequences.count)
        #expect(await log.cursor == second.cursor)
    }

    @Test("append gives the time of the event")
    func appendGivesTheTime() async {
        let log = ChangeLog<String>()
        let before = Date()

        let entry = await log.append("a")

        #expect(entry.at >= before)
        #expect(entry.at <= Date())
        #expect(entry.event == "a")
    }

    @Test("two logs have different epochs, so a cursor of one does not resume the other")
    func twoLogsHaveDifferentEpochs() async throws {
        let one = ChangeLog<String>()
        let other = ChangeLog<String>()

        let oneEpoch = try #require(ChangeLogCursor(parsing: await one.cursor)).epoch
        let otherEpoch = try #require(ChangeLogCursor(parsing: await other.cursor)).epoch

        #expect(oneEpoch != otherEpoch)
        #expect(await Self.endingError(of: await other.changes(after: await one.cursor))?.code == Self.resyncCode)
    }

    // MARK: - Replay and live events

    @Test("the cursor of an empty log waits for the first event")
    func emptyLogCursorWaitsForTheFirstEvent() async throws {
        let log = ChangeLog<String>()
        let stream = await log.changes(after: await log.cursor)

        await log.append("a")

        #expect(try await Self.events(like: ["a"], of: stream) == ["a"])
    }

    @Test("changes after a cursor replays the buffered events after it, then the live events, in order")
    func replayThenLive() async throws {
        let log = ChangeLog<String>()
        let first = await log.append("a")
        await log.append("b")
        await log.append("c")
        let expected = ["b", "c", "d"]

        let stream = await log.changes(after: first.cursor)
        await log.append("d")

        #expect(try await Self.events(like: expected, of: stream) == expected)
    }

    @Test("each entry carries the cursor that resumes after it")
    func entryCursorResumesAfterIt() async throws {
        let log = ChangeLog<String>()
        let stream = await log.changes(after: await log.cursor)
        await log.append("a")
        await log.append("b")
        var iterator = stream.makeAsyncIterator()
        let first = try #require(try await iterator.next())

        let resumed = await log.changes(after: first.cursor)
        await log.append("c")
        let expected = ["b", "c"]

        #expect(try await Self.events(like: expected, of: resumed) == expected)
    }

    @Test("changes after nil gives only the live events")
    func afterNilIsLiveOnly() async throws {
        let log = ChangeLog<String>()
        await log.append("old")

        let stream = await log.changes(after: nil)
        await log.append("new")

        #expect(try await Self.events(like: ["new"], of: stream) == ["new"])
    }

    @Test("the predicate filters the replay and the live events of one subscriber, and keeps the order")
    func predicateFiltersPerSubscriber() async throws {
        let log = ChangeLog<String>()
        let start = await log.cursor
        await log.append("keep 1")
        await log.append("drop 1")
        let kept = ["keep 1", "keep 2"]
        let all = ["keep 1", "drop 1", "drop 2", "keep 2"]

        let filtered = await log.changes(after: start) { event in event.hasPrefix("keep") }
        let everything = await log.changes(after: start)
        await log.append("drop 2")
        await log.append("keep 2")

        #expect(try await Self.events(like: kept, of: filtered) == kept)
        #expect(try await Self.events(like: all, of: everything) == all)
    }

    // MARK: - RESYNC_REQUIRED

    @Test("a cursor whose next events left the buffer ends the stream with RESYNC_REQUIRED")
    func evictedCursorNeedsResync() async {
        let log = ChangeLog<String>(capacity: Self.smallCapacity)
        let start = await log.cursor
        for event in ["a", "b", "c"] {
            await log.append(event)
        }

        #expect(await Self.endingError(of: await log.changes(after: start))?.code == Self.resyncCode)
    }

    @Test("a cursor just before the oldest buffered event replays the whole buffer")
    func cursorBeforeTheOldestReplaysTheBuffer() async throws {
        let log = ChangeLog<String>(capacity: Self.smallCapacity)
        let first = await log.append("a")
        await log.append("b")
        await log.append("c")
        let buffered = ["b", "c"]

        #expect(try await Self.events(like: buffered, of: await log.changes(after: first.cursor)) == buffered)
    }

    @Test("a cursor after the newest event ends the stream with RESYNC_REQUIRED")
    func cursorAfterTheNewestNeedsResync() async throws {
        let log = ChangeLog<String>()
        let epoch = try #require(ChangeLogCursor(parsing: await log.cursor)).epoch
        let ahead = ChangeLogCursor(epoch: epoch, sequence: Self.unreachedSequence).text

        #expect(await Self.endingError(of: await log.changes(after: ahead))?.code == Self.resyncCode)
    }

    @Test("a cursor that does not parse ends the stream with RESYNC_REQUIRED", arguments: ["", "x", "a:b", "a:1:2"])
    func unparsedCursorNeedsResync(cursor: String) async {
        let log = ChangeLog<String>()

        #expect(await Self.endingError(of: await log.changes(after: cursor))?.code == Self.resyncCode)
    }

    @Test("a subscriber that falls more than the buffer size behind gets the buffered events, then RESYNC_REQUIRED")
    func slowSubscriberNeedsResync() async throws {
        let log = ChangeLog<String>(capacity: Self.smallCapacity)
        let stream = await log.changes(after: nil)
        for event in ["a", "b", "c"] {
            await log.append(event)
        }
        var iterator = stream.makeAsyncIterator()

        #expect(try await iterator.next()?.event == "a")
        #expect(try await iterator.next()?.event == "b")
        let error = await #expect(throws: GraphQLToolkitError.self) {
            _ = try await iterator.next()
        }
        #expect(error?.code == Self.resyncCode)
    }

    // MARK: - Subscribers

    @Test("a terminated stream removes its subscriber")
    func terminatedStreamRemovesItsSubscriber() async throws {
        let log = ChangeLog<String>()
        let kept = await log.changes(after: nil)

        _ = await log.changes(after: nil)
        await log.append("a")

        #expect(await log.subscriberCount == 1)
        #expect(try await Self.events(like: ["a"], of: kept) == ["a"])
    }

    @Test("a stream that ends with RESYNC_REQUIRED has no subscriber")
    func resyncLeavesNoSubscriber() async {
        let log = ChangeLog<String>()

        _ = await log.changes(after: "x")

        #expect(await log.subscriberCount == 0)
    }

    // MARK: - ID changes

    @Test("an id change gives the cursor, the time, and the ids of its entry")
    func idChangeGivesTheEntry() async {
        let log = ChangeLog<ChangedIDs>()

        let entry = await log.append(ChangedIDs(added: ["n2"], changed: ["n1"], removed: ["n0"]))
        let change = IDChange(entry)

        #expect(change.cursor == entry.cursor)
        #expect(change.at == DateTime(entry.at))
        #expect(change.added == ["n2"])
        #expect(change.changed == ["n1"])
        #expect(change.removed == ["n0"])
    }
}
