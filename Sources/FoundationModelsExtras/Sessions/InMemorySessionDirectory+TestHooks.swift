import ULID

/// The test hooks of the test double: they drive the state of a session the
/// way a model turn would, and they end the event streams.
extension InMemorySessionDirectory {
    /// Adds a session that the test made, for example a subagent, a fork or
    /// a recorded session that is not live, as the Router registers a vended
    /// session. A live session sends `started` while it is idle, then
    /// `stateChanged` to the state of `summary`. A session that is not live
    /// sends no event. A summary with the id of a session that the directory
    /// holds replaces that session.
    ///
    /// - Parameter summary: The summary of the session.
    public func register(_ summary: SessionSummary) {
        let time = now()
        state.withLock { $0.register(summary, at: time) }
    }

    /// Starts a turn that a user started in the session `id`: the state
    /// becomes working, the directory sends `stateChanged`, and a message
    /// that the turn sends has chain depth 1. An archived session stays as
    /// it is.
    ///
    /// - Parameter id: The session id.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    public func startUserTurn(of id: ULID) throws {
        let time = now()
        try state.withLock { try $0.startUserTurn(of: id, at: time) }
    }

    /// Makes the turn of the session `id` wait for an answer, as an
    /// elicitation or a permission request does: the state becomes
    /// needsInput, and the directory sends `stateChanged`. An archived
    /// session stays as it is.
    ///
    /// - Parameter id: The session id.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    public func requestInput(of id: ULID) throws {
        let time = now()
        try state.withLock { try $0.requestInput(of: id, at: time) }
    }

    /// Ends the current turn of the session `id`: the state becomes idle,
    /// with the last summary, and the directory sends `stateChanged`. Then
    /// the queued messages that are not read start the next turn. An
    /// archived session stays as it is.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - lastSummary: The last final message of the turn.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    public func finishTurn(of id: ULID, lastSummary: String?) throws {
        let time = now()
        try state.withLock { try $0.finishTurn(of: id, lastSummary: lastSummary, at: time) }
    }

    /// Finishes each open event stream. A reader then reads the events that
    /// the stream holds, and its loop ends. A test reads a stream this way
    /// with no clock.
    public func finishEventStreams() {
        for continuation in state.withLock({ $0.removeSubscribers() }) {
            continuation.finish()
        }
    }
}
