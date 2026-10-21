import Foundation

/// One event of a ``ChangeLog``, with the cursor that resumes after it and the time that the log took it.
///
/// The `changes` stream of a log gives these entries. A resolver of a `changes` subscription fills the `cursor` and
/// the `at` fields of its `<Noun>Change` type from the entry, and the other fields from ``event``.
public struct ChangeLogEntry<Event: Sendable>: Sendable {
    /// The cursor of the event: an opaque text. `changes(after:)` with this cursor resumes after this event.
    public let cursor: String

    /// The time that the log took the event.
    public let at: Date

    /// The event.
    public let event: Event
}

/// The cursor of a ``ChangeLog``: the epoch of the log, and the sequence number of one event.
///
/// The wire form is the opaque text `<epoch>:<sequence>`, as the `cursor: String!` field and the
/// `changes(after: String)` argument of a schema give it. A caller does not read the text; it only sends it back.
struct ChangeLogCursor: Hashable, Sendable {
    /// The text between the epoch and the sequence number.
    static let separator: Character = ":"

    /// The number of parts of the text: the epoch and the sequence number.
    static let partCount = 2

    /// The epoch of the log that gave the cursor. Each log instance has its own random epoch.
    let epoch: String

    /// The sequence number of the event, or 0 for the cursor of a log with no event yet.
    let sequence: UInt64

    /// Makes a cursor.
    ///
    /// - Parameters:
    ///   - epoch: The epoch of the log.
    ///   - sequence: The sequence number of the event.
    init(epoch: String, sequence: UInt64) {
        self.epoch = epoch
        self.sequence = sequence
    }

    /// Reads a cursor from its wire text.
    ///
    /// - Parameter text: The wire text, `<epoch>:<sequence>`.
    /// - Returns: `nil` when the text is not a cursor.
    init?(parsing text: String) {
        let parts = text.split(separator: Self.separator, omittingEmptySubsequences: false)
        guard parts.count == Self.partCount, let epoch = parts.first, !epoch.isEmpty,
            let sequence = parts.last.flatMap({ UInt64($0) })
        else {
            return nil
        }
        self.init(epoch: String(epoch), sequence: sequence)
    }

    /// The wire text of the cursor.
    var text: String {
        "\(epoch)\(Self.separator)\(sequence)"
    }
}

/// The change log of one endpoint: the source of a `changes` subscription, with a cursor that resumes it.
///
/// Each mutation appends one event with ``append(_:)``. A client first queries the state with its ``cursor``, then
/// subscribes with `changes(after:)` and that cursor, so that it gets each change after the state it read, with
/// no gap and no repeat.
///
/// The log keeps the newest events in a buffer of fixed size, the `capacity` of ``init(capacity:)``. Each instance
/// has a random epoch, so a cursor of an earlier run of the endpoint does not resume a later one. A subscription that
/// cannot resume with no gap ends with ``GraphQLToolkitError/resyncRequired(reason:)``: the caller queries the state
/// again, and subscribes with the new cursor.
public actor ChangeLog<Event: Sendable> {
    /// The stream of one subscriber.
    public typealias Changes = AsyncThrowingStream<ChangeLogEntry<Event>, Error>

    /// One live subscriber: its stream and its filter.
    private struct Subscriber {
        /// The continuation of the stream of the subscriber.
        let continuation: Changes.Continuation

        /// Tells if the subscriber gets an event.
        let isIncluded: @Sendable (Event) -> Bool
    }

    /// The random epoch of this instance.
    private let epoch = UUID().uuidString

    /// The most events that the buffer holds, and the most events that one subscriber can fall behind.
    private let capacity: Int

    /// The newest events, oldest first. The buffer holds at most ``capacity`` events.
    private var buffer: [ChangeLogEntry<Event>] = []

    /// The sequence number of the newest event, or 0 when the log has no event yet.
    private var newestSequence: UInt64 = 0

    /// The live subscribers, by their id.
    private var subscribers: [UInt64: Subscriber] = [:]

    /// The id of the next subscriber.
    private var nextSubscriberID: UInt64 = 0

    /// Makes an empty log with a new random epoch.
    ///
    /// - Parameter capacity: The number of the newest events that the buffer holds, so that a subscription can
    ///   resume after a cursor that is at most this many events old. A subscriber that falls more than this many
    ///   events behind also ends with `RESYNC_REQUIRED`. It must be at least 1.
    public init(capacity: Int = 1024) {
        precondition(capacity > 0, "The capacity of a ChangeLog must be at least 1.")
        self.capacity = capacity
    }

    /// The cursor of the newest event. The cursor of a log with no event is valid too, so `changes(after:)` with it
    /// waits for the first event.
    public var cursor: String {
        ChangeLogCursor(epoch: epoch, sequence: newestSequence).text
    }

    /// The number of live subscribers.
    var subscriberCount: Int {
        subscribers.count
    }

    /// Stores an event, and gives it to each live subscriber whose filter includes it.
    ///
    /// The buffer drops its oldest event when it is full.
    ///
    /// - Parameter event: The event.
    /// - Returns: The entry of the event: its cursor, which is after each earlier cursor, and its time.
    @discardableResult
    public func append(_ event: Event) -> ChangeLogEntry<Event> {
        newestSequence += 1
        let entry = ChangeLogEntry(
            cursor: ChangeLogCursor(epoch: epoch, sequence: newestSequence).text,
            at: Date(),
            event: event
        )
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for id in Array(subscribers.keys) {
            deliver(entry, to: id)
        }
        return entry
    }

    /// Gives the changes after a cursor: first the buffered events after it, then the live events, in order.
    ///
    /// The stream ends with ``GraphQLToolkitError/resyncRequired(reason:)`` when the log cannot give each event
    /// after the cursor:
    ///
    /// - the cursor does not parse;
    /// - the cursor has another epoch, for example it is from another instance of the log;
    /// - the cursor is after the newest event;
    /// - an event after the cursor left the buffer;
    /// - the subscriber falls more than the buffer size behind.
    ///
    /// A stream that terminates removes its subscriber.
    ///
    /// - Parameters:
    ///   - cursor: The cursor to resume after, or `nil` for the live events only, with no replay.
    ///   - isIncluded: Tells if this subscriber gets an event. It filters the replay and the live events, and keeps
    ///     their order. The default includes each event.
    /// - Returns: The stream of the entries.
    public func changes(
        after cursor: String?,
        where isIncluded: @escaping @Sendable (Event) -> Bool = { _ in true }
    ) -> Changes {
        let (stream, continuation) = Changes.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        let replay: ArraySlice<ChangeLogEntry<Event>>
        do {
            replay = try entries(after: cursor)
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        for entry in replay where isIncluded(entry.event) {
            continuation.yield(entry)
        }
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = Subscriber(continuation: continuation, isIncluded: isIncluded)
        continuation.onTermination = { [weak self] _ in
            guard let self else {
                return
            }
            Task { await self.removeSubscriber(id) }
        }
        return stream
    }

    /// Gives the buffered events after a cursor.
    ///
    /// - Parameter text: The wire text of the cursor, or `nil` for no replay.
    /// - Returns: The buffered events after the cursor, oldest first.
    /// - Throws: ``GraphQLToolkitError/resyncRequired(reason:)`` when the buffer does not hold each event after the
    ///   cursor.
    private func entries(after text: String?) throws(GraphQLToolkitError) -> ArraySlice<ChangeLogEntry<Event>> {
        guard let text else {
            return []
        }
        guard let cursor = ChangeLogCursor(parsing: text) else {
            throw .resyncRequired(reason: "The cursor \"\(text)\" is not a cursor of this endpoint.")
        }
        guard cursor.epoch == epoch else {
            throw .resyncRequired(reason: "The cursor \"\(text)\" is from another run of the endpoint.")
        }
        guard cursor.sequence <= newestSequence else {
            throw .resyncRequired(reason: "The cursor \"\(text)\" is after the newest change.")
        }
        guard cursor.sequence >= newestSequence - UInt64(buffer.count) else {
            throw .resyncRequired(
                reason: "The changes after the cursor \"\(text)\" left the buffer of the newest \(capacity) changes.")
        }
        return buffer.suffix(Int(newestSequence - cursor.sequence))
    }

    /// Gives an entry to one subscriber, when its filter includes the event.
    ///
    /// A subscriber whose stream terminated is removed. A subscriber whose stream buffer is full is more than the
    /// buffer size behind: its stream ends with `RESYNC_REQUIRED` after the events that it holds.
    ///
    /// - Parameters:
    ///   - entry: The entry.
    ///   - id: The id of the subscriber.
    private func deliver(_ entry: ChangeLogEntry<Event>, to id: UInt64) {
        guard let subscriber = subscribers[id], subscriber.isIncluded(entry.event) else {
            return
        }
        switch subscriber.continuation.yield(entry) {
        case .enqueued:
            break
        case .dropped:
            subscribers[id] = nil
            subscriber.continuation.finish(
                throwing: GraphQLToolkitError.resyncRequired(
                    reason: "The subscriber fell more than \(capacity) changes behind."))
        case .terminated:
            subscribers[id] = nil
        @unknown default:
            subscribers[id] = nil
        }
    }

    /// Removes a subscriber whose stream terminated.
    ///
    /// - Parameter id: The id of the subscriber.
    private func removeSubscriber(_ id: UInt64) {
        subscribers[id] = nil
    }
}
