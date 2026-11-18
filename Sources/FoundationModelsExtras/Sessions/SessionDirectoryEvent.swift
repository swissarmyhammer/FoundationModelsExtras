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

    /// Tags, title, pin or last use changed.
    case factsChanged(SessionSummary)

    /// The work state of the session changed. `lastSummary` is the last
    /// final message of the session, when the state is idle.
    case stateChanged(id: ULID, state: SessionState, lastSummary: String?)

    /// The target took a message. The message holds the sender, the source
    /// session and the text. The host of the target uses this event to show
    /// the message.
    ///
    /// Each message gives this event one time, when the target takes it:
    ///
    /// - A message to an idle target gives it at once, when the turn of the
    ///   message starts.
    /// - A queued message gives no event at the send. It gives the event
    ///   when the turn for that message starts, before the first model
    ///   output of the turn.
    /// - An inbox read with `markRead` of a message that is still queued
    ///   takes it, thus the read gives the event. A later turn gives no
    ///   second event for that message.
    /// - A send to a recorded session that is not live puts the message in
    ///   its inbox and gives no event. The event comes when the target takes
    ///   the message.
    ///
    /// A refused, cancelled or lost message gives no event. A queued message
    /// of a session that closes or is archived before it takes the message
    /// gives no event.
    case messageDelivered(SessionMessage)

    /// The session is archived (ROUTER-11).
    case archived(id: ULID)
}
