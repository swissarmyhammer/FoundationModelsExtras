/// A party that takes ``Mail``, for example a session.
///
/// The event type is an associated type, because this package does not know
/// the event type of the session. Router uses its session event type.
public protocol MailSink: Sendable {
    /// The type of the output events of the sink.
    associatedtype Event: Sendable

    /// Puts one mail in the mail queue of the sink.
    ///
    /// The sink subscribes first, then puts the mail in the queue. Thus the
    /// caller loses no event of the mail. A caller that does not need the
    /// events drops the subscription.
    ///
    /// - Parameter mail: The mail to put in the queue.
    /// - Returns: The output events of the mail.
    /// - Throws: ``MailRefusal/duplicateID(_:)`` when the sink already has a
    ///   mail with this id, or ``MailRefusal/closed`` when the sink is
    ///   closed.
    func mail(_ mail: Mail) throws -> MailSubscription<Event>
}

/// The output events of one ``Mail``.
///
/// The subscription gives each output event whose origin contains the id
/// of the mail, up to and including its terminal event. Then it ends. It
/// has its own unbounded buffer, thus a slow reader loses no events.
public struct MailSubscription<Event: Sendable>: AsyncSequence, Sendable {
    /// The type of the iterator of the events.
    public typealias AsyncIterator = AsyncStream<Event>.Iterator

    /// The id of the mail.
    public let id: MailID

    /// The events of the mail.
    private let events: AsyncStream<Event>

    /// Makes a subscription.
    ///
    /// The sink makes the stream with an unbounded buffer, and finishes it
    /// after the terminal event of the mail.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - events: The events of the mail.
    public init(id: MailID, events: AsyncStream<Event>) {
        self.id = id
        self.events = events
    }

    /// Makes an iterator over the events of the mail.
    public func makeAsyncIterator() -> AsyncIterator {
        events.makeAsyncIterator()
    }
}

/// Why a ``MailSink`` refused a mail.
public enum MailRefusal: Error, Sendable, Equatable {
    /// The sink already has a mail with this id, in the queue or in an
    /// open answer.
    case duplicateID(MailID)

    /// The sink is closed and takes no more mail.
    case closed
}
