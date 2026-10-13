@testable import FoundationModelsExtras
import Synchronization
import Testing

/// A ``MailSink`` subscribes before it puts the mail in the queue, thus the
/// subscription loses no event. It refuses a duplicate id.
@Suite("MailSink: the subscription loses no events, and a duplicate id throws")
struct MailSinkTests {
    /// A body for the tests.
    private static let body = MailBody.userMessage(prompt: "Hello", options: UserMessageOptions())

    @Test("events sent before the first next() are not lost, and the sequence ends after the stream finishes")
    func earlyEventsAreNotLost() async throws {
        let sink = RecordingMailSink()
        let subscription = try sink.mail(Mail(sender: .user, body: Self.body))

        sink.send("started", to: subscription.id)
        sink.send("text", to: subscription.id)
        sink.send("answered", to: subscription.id)
        sink.finish(subscription.id)

        var events: [String] = []
        for await event in subscription {
            events.append(event)
        }
        #expect(events == ["started", "text", "answered"])
    }

    @Test("the subscription has the id of the mail")
    func theSubscriptionHasTheMailID() throws {
        let sink = RecordingMailSink()
        let mail = Mail(sender: .user, body: Self.body)

        #expect(try sink.mail(mail).id == mail.id)
    }

    @Test("a second mail with the same id throws duplicateID")
    func aDuplicateIDThrows() throws {
        let sink = RecordingMailSink()
        let id = MailID()
        _ = try sink.mail(Mail(id: id, sender: .user, body: Self.body))

        #expect(throws: MailRefusal.duplicateID(id)) {
            try sink.mail(Mail(id: id, sender: .user, body: Self.body))
        }
    }
}

/// A sink for the tests. It keeps one unbounded stream for each mail, and
/// the test sends the events and finishes each stream.
private final class RecordingMailSink: MailSink {
    /// The open streams, by the id of their mail.
    private let streams = Mutex<[MailID: AsyncStream<String>.Continuation]>([:])

    func mail(_ mail: Mail) throws -> MailSubscription<String> {
        let (events, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        try streams.withLock { streams in
            guard streams[mail.id] == nil else {
                throw MailRefusal.duplicateID(mail.id)
            }
            streams[mail.id] = continuation
        }
        return MailSubscription(id: mail.id, events: events)
    }

    /// Sends one event to the subscription of a mail.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - id: The id of the mail.
    func send(_ event: String, to id: MailID) {
        _ = streams.withLock { $0[id] }?.yield(event)
    }

    /// Finishes the subscription of a mail, as after its terminal event.
    ///
    /// - Parameter id: The id of the mail.
    func finish(_ id: MailID) {
        streams.withLock { $0[id] }?.finish()
    }
}
