import Foundation
import Synchronization
import ULID

/// A test double of ``SessionDirectory``. It holds sessions, tags, titles
/// and messages in memory.
///
/// **This is a test double, not a production directory.** The Router
/// implements the real directory. The tests of Multitool,
/// FoundationModelsAgents, the `sessions` graph and ACPAgent use this one,
/// with no Router and no model. It lives in the library target, because the
/// package has no test-support product (D73).
///
/// It follows the rules of the real directory (session.md):
///
/// - **Start (section 6):** a fake ``Launcher`` knows a list of agent ids. A
///   nil agent is the default agent, and a nil folder is the folder of
///   `startedBy`. An unknown id throws `unknownAgent` with the near names.
///   With no launcher, `start` and an agent send throw `noLauncher`.
/// - **Delivery (section 10.2):** an idle target gets `delivered`, and the
///   message starts a turn. A working target, or one that needs input, gets
///   `queued`. An archived target gets `refused` with the reason "archived".
///   An agent address with no live root session starts one (origin
///   ``SessionDirectoryOrigin/message``). A folder with no match is refused.
/// - **Loop guards (section 10.3):** the ``LoopGuards``.
/// - **Archive (ROUTER-11):** an archived session takes no message.
/// - **Events (section 7):** each ``events()`` call is a new stream with the
///   `.bufferingNewest(256)` policy, and `started` comes before the first
///   `stateChanged` of a session.
///
/// The body-choice rule of ``SessionDirectory/send(_:)`` holds for each
/// message: ``mail(carrying:)`` gives the mail that carries it. The test
/// double keeps no mail queue.
///
/// No model runs a turn. A delivery to an idle session starts a turn, and
/// the test hooks start and end the other turns: ``startUserTurn(of:)``,
/// ``requestInput(of:)`` and ``finishTurn(of:lastSummary:)``. When a turn
/// ends, the queued messages that are not read start the next turn.
public final class InMemorySessionDirectory: SessionDirectory {
    /// The most events that one stream of ``events()`` buffers. A slow
    /// reader loses the old events, not the new ones.
    public static let eventBufferLimit = 256

    /// The sessions, the messages and the event streams. The test hooks in
    /// the extension of this type change it too.
    let state: Mutex<InMemorySessionDirectoryState>

    /// The clock that stamps each change.
    let now: @Sendable () -> Date

    /// Makes an empty directory.
    ///
    /// - Parameters:
    ///   - launcher: The fake launcher. The default is `nil`: `start` and an
    ///     agent send throw ``SessionDirectoryError/noLauncher``.
    ///   - loopGuards: The loop guards. The default is the default guards of
    ///     session.md section 10.3.
    ///   - now: The clock that stamps each change. The default is the system
    ///     clock. A test gives a fixed time.
    public init(
        launcher: Launcher? = nil,
        loopGuards: LoopGuards = LoopGuards(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        state = Mutex(InMemorySessionDirectoryState(launcher: launcher, loopGuards: loopGuards))
        self.now = now
    }

    /// The summaries of the sessions that match the query, the newest
    /// first, at most ``SessionQuery/limit`` of them.
    ///
    /// - Parameter query: The filter. Each field that is not nil must match.
    /// - Returns: The summaries of the matching sessions.
    public func sessions(matching query: SessionQuery) async throws -> [SessionSummary] {
        state.withLock { $0.summaries(matching: query) }
    }

    /// The summary of one session.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary, or `nil` when no session has this id.
    public func summary(of id: ULID) async throws -> SessionSummary? {
        state.withLock { $0.entries[id]?.summary }
    }

    /// Starts a new root session through the fake launcher, and sends
    /// `started`. The first message starts a turn, thus the session works.
    ///
    /// - Parameter request: The agent, the working folder and the first
    ///   message of the session.
    /// - Returns: The summary of the new session.
    /// - Throws: ``SessionDirectoryError/noLauncher``,
    ///   ``SessionDirectoryError/unknownAgent(_:nearNames:)``,
    ///   ``SessionDirectoryError/unknownSession(_:)`` for an unknown
    ///   `startedBy`, and ``SessionDirectoryError/invalidTag(_:)``.
    public func start(_ request: SessionStartRequest) async throws -> SessionSummary {
        let time = now()
        return try state.withLock { try $0.start(request, at: time) }
    }

    /// Adds tags to the session `id` and sends `factsChanged`.
    ///
    /// - Parameters:
    ///   - tags: The tags to add.
    ///   - id: The session id.
    /// - Returns: The summary with the new tags.
    /// - Throws: ``SessionDirectoryError/invalidTag(_:)`` and
    ///   ``SessionDirectoryError/unknownSession(_:)``.
    public func addTags(_ tags: Set<String>, to id: ULID) async throws -> SessionSummary {
        try changeFacts(of: id, checking: tags) { $0.tags.formUnion(tags) }
    }

    /// Removes tags from the session `id` and sends `factsChanged`.
    ///
    /// - Parameters:
    ///   - tags: The tags to remove.
    ///   - id: The session id.
    /// - Returns: The summary with the tags that stay.
    /// - Throws: ``SessionDirectoryError/invalidTag(_:)`` and
    ///   ``SessionDirectoryError/unknownSession(_:)``.
    public func removeTags(_ tags: Set<String>, from id: ULID) async throws -> SessionSummary {
        try changeFacts(of: id, checking: tags) { $0.tags.subtract(tags) }
    }

    /// Sets the title of `id` and sends `factsChanged`.
    ///
    /// - Parameters:
    ///   - title: The new title.
    ///   - id: The session id.
    /// - Returns: The summary with the new title.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    public func setTitle(_ title: String, of id: ULID) async throws -> SessionSummary {
        try changeFacts(of: id, checking: []) { $0.title = title }
    }

    /// Checks the tags, then changes the facts of a session, and sends
    /// `factsChanged` when they changed.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - tags: The tags of the call, to check against the tag rule.
    ///   - change: The change of the summary.
    /// - Returns: The summary after the change.
    /// - Throws: ``SessionDirectoryError/invalidTag(_:)`` and
    ///   ``SessionDirectoryError/unknownSession(_:)``.
    private func changeFacts(
        of id: ULID,
        checking tags: Set<String>,
        _ change: (inout SessionSummary) -> Void
    ) throws -> SessionSummary {
        try InMemorySessionDirectoryState.validate(tags)
        let time = now()
        return try state.withLock { try $0.changeFacts(of: id, at: time, change) }
    }

    /// Sends a message to each session that the address names, with the
    /// loop guards and the delivery rules of session.md sections 9, 10.2 and
    /// 10.3. Each delivery sends `messageDelivered`.
    ///
    /// - Parameter message: The sender, the address, the text and the reply
    ///   id of the message.
    /// - Returns: One receipt for each target session. A refusal of a loop
    ///   guard, or of an address that matches no session, gives one
    ///   `refused` receipt with no target. ``Refusal`` names each reason.
    /// - Throws: ``SessionDirectoryError/messageTooLong(limit:)``,
    ///   ``SessionDirectoryError/invalidTag(_:)``,
    ///   ``SessionDirectoryError/unknownSession(_:)`` for an unknown sender or
    ///   target session, and for an agent address that starts a session,
    ///   ``SessionDirectoryError/noLauncher`` and
    ///   ``SessionDirectoryError/unknownAgent(_:nearNames:)``.
    public func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt] {
        let time = now()
        return try state.withLock { try $0.send(message, at: time) }
    }

    /// The messages to `id` that are not read. With `markRead`, they become
    /// read, and a queued message does not start a turn later.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - markRead: True to mark the messages read.
    /// - Returns: The messages that were not read, the oldest first.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    public func inbox(of id: ULID, markRead: Bool) async throws -> [SessionMessage] {
        try state.withLock { try $0.inbox(of: id, markRead: markRead) }
    }

    /// One message that the directory delivered to `recipient`, read or not
    /// read, found by its id. The lookup marks nothing read.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - recipient: The session id that the message went to.
    /// - Returns: The message, with its read flag, or `nil` when no message
    ///   has the id or the message went to another session. An unknown
    ///   recipient gives `nil` too, because no message went to it.
    public func message(_ id: MailID, to recipient: ULID) async throws -> SessionMessage? {
        state.withLock { $0.message(id, to: recipient) }
    }

    /// Archives the session `id` (ROUTER-11): it stops its turn, leaves the
    /// live list, takes no more message, and the directory sends `archived`.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - archiver: The session or the user that archives it. The test
    ///     double keeps no audit, thus it reads no field of it.
    /// - Returns: The summary of the archived session.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    public func archive(_ id: ULID, by archiver: SessionMessageSender) async throws -> SessionSummary {
        let time = now()
        return try state.withLock { try $0.archive(id, at: time) }
    }

    /// A new stream with the `.bufferingNewest(256)` policy. It gets each
    /// event after the call, until ``finishEventStreams()`` or until the
    /// reader drops it.
    ///
    /// - Returns: A stream of the changes in the directory.
    public func events() -> AsyncStream<SessionDirectoryEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SessionDirectoryEvent.self, bufferingPolicy: .bufferingNewest(Self.eventBufferLimit))
        let subscriberID = state.withLock { $0.subscribe(continuation) }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.unsubscribe(subscriberID) }
        }
        return stream
    }
}
