import ULID

/// One change in the directory. ``SessionDirectory/events()`` gives these.
///
/// The directory sends one event for each change. The events of one session
/// come in order, and `started` comes before the first `stateChanged` of
/// that session. Subagent sessions also give events. An event holds no
/// message text that is longer than the message length limit (ROUTER-5).
public enum SessionDirectoryEvent: Sendable, Codable, Equatable {
    /// A session started: new, restored or forked. `requestedByClient` is
    /// the UI client that asked for the start, for the tab rule.
    case started(SessionSummary, requestedByClient: String?)

    /// Tags, title, pin or last use changed, or the directory imported a
    /// session that is recorded and not live.
    case factsChanged(SessionSummary)

    /// The work state of the session changed. `lastSummary` is the last
    /// final message of the session, when the state is idle.
    case stateChanged(id: ULID, state: SessionState, lastSummary: String?)

    /// The directory put a message in the queue of a working target, or in
    /// the inbox of a recorded or archived target. The target did not take the message
    /// yet. The message holds the sender, the source session and the text.
    /// A host uses this event to show the count of the messages that are not
    /// read.
    ///
    /// The event comes at the send, before the send returns its receipt.
    /// `messageDelivered` of the same message comes later, when the target
    /// takes it. A message to an idle target starts its turn at once, thus
    /// it gives only `messageDelivered`. A refused message gives no event.
    case messageQueued(SessionMessage)

    /// The target took a message. The message holds the sender, the source
    /// session and the text. The host of the target uses this event to show
    /// the message.
    ///
    /// Each message gives this event one time, when the target takes it:
    ///
    /// - A message to an idle target gives it at once, when the turn of the
    ///   message starts.
    /// - A queued message gives `messageQueued` at the send, not this
    ///   event. It gives this event when the turn for that message starts,
    ///   before the first model output of the turn.
    /// - An inbox read with `markRead` of a message that is still queued
    ///   takes it, thus the read gives the event. A later turn gives no
    ///   second event for that message.
    /// - A send to a recorded session that is not live puts the message in
    ///   its inbox and gives `messageQueued`. This event comes when the
    ///   target takes the message.
    ///
    /// A refused, cancelled or lost message gives no event. A queued message
    /// of a session that closes or is archived before it takes the message
    /// gives no `messageDelivered` then. The message stays in the inbox of
    /// the session, and the event comes when the session takes it later.
    case messageDelivered(SessionMessage)

    /// The session is archived (ROUTER-11).
    case archived(id: ULID)

    /// The session is not archived now. It is a recorded session that is
    /// not live, and `stateChanged` with `idle` comes before this event.
    case unarchived(id: ULID)
}
