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

    /// Tags or title changed.
    case factsChanged(SessionSummary)

    /// The work state of the session changed. `lastSummary` is the last
    /// final message of the session, when the state is idle.
    case stateChanged(id: ULID, state: SessionState, lastSummary: String?)

    /// The directory put a message in the queue of the target, and the
    /// target recorded it.
    case messageDelivered(SessionMessage)

    /// The session is archived (ROUTER-11).
    case archived(id: ULID)
}
