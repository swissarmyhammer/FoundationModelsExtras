import ULID

/// The session directory: find, start, tag and message sessions.
///
/// The Router implements it. The `sessions` tool, the `sessions` graph and
/// the trigger handler use it. It has no ACP concept.
public protocol SessionDirectory: Sendable {
    /// The summaries of the sessions that match the query, at most
    /// ``SessionQuery/limit`` of them.
    ///
    /// - Parameter query: The filter. Each field that is not nil must match.
    /// - Returns: The summaries of the matching sessions.
    func sessions(matching query: SessionQuery) async throws -> [SessionSummary]

    /// The summary of one session.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary, or `nil` when no session has this id.
    func summary(of id: ULID) async throws -> SessionSummary?

    /// Starts a new root session and sends `started`.
    ///
    /// - Parameter request: The agent, the working folder and the first
    ///   message of the session.
    /// - Returns: The summary of the new session.
    func start(_ request: SessionStartRequest) async throws -> SessionSummary

    /// Forks a session and sends `started`.
    ///
    /// The fork is a new top-level session of kind ``SessionKind/fork``, with
    /// the origin ``SessionDirectoryOrigin/fork``. It works in the folder of
    /// its source, with the agent of its source, and its
    /// ``SessionSummary/parentID`` is the source. It gets a copy of the
    /// history of the source up to the cut of the request. Its name is
    /// ``SessionName/fork(sourceName:usedNames:)`` of the slug of the source,
    /// outside the names of the sessions in that folder that are not
    /// archived. The `started` event has the kind `fork` and the parent. A
    /// first prompt starts the first turn of the fork, as the first message
    /// of a start does.
    ///
    /// - Parameter request: The source, the cut, the first prompt, the client
    ///   and the forker.
    /// - Returns: The summary of the fork.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` for an unknown
    ///   source, ``SessionDirectoryError/archivedSession(_:)`` for an
    ///   archived source, ``SessionDirectoryError/forkCutOutOfRange(_:)`` for
    ///   a cut that is not in the history of the source, and
    ///   ``SessionDirectoryError/forkUnsupported`` from a directory that
    ///   cannot fork.
    func fork(_ request: SessionForkRequest) async throws -> SessionSummary

    /// Adds tags to the session `id` and sends `factsChanged`.
    ///
    /// - Parameters:
    ///   - tags: The tags to add.
    ///   - id: The session id.
    /// - Returns: The summary with the new tags.
    func addTags(_ tags: Set<String>, to id: ULID) async throws -> SessionSummary

    /// Removes tags from the session `id` and sends `factsChanged`.
    ///
    /// - Parameters:
    ///   - tags: The tags to remove.
    ///   - id: The session id.
    /// - Returns: The summary with the tags that stay.
    func removeTags(_ tags: Set<String>, from id: ULID) async throws -> SessionSummary

    /// Sets the title of `id` (Rename, a control action: TestudoApp D84), and
    /// sends `factsChanged`.
    ///
    /// - Parameters:
    ///   - title: The new title.
    ///   - id: The session id.
    /// - Returns: The summary with the new title.
    func setTitle(_ title: String, of id: ULID) async throws -> SessionSummary

    /// Pins or unpins the session `id` (Pin Session and Unpin Session, D118),
    /// and sends `factsChanged` when the pin changes.
    ///
    /// A pin sets ``SessionSummary/pinnedAt`` to the time of the call. A pin
    /// of a pinned session keeps its first time, thus its place in the pin
    /// order. An unpin sets it to `nil`.
    ///
    /// - Parameters:
    ///   - pinned: True to pin the session, false to unpin it.
    ///   - id: The session id.
    /// - Returns: The summary with the new pin.
    func setPinned(_ pinned: Bool, of id: ULID) async throws -> SessionSummary

    /// Records that a client used the session `id` now, for example that it
    /// opened the session (D184). It sets ``SessionSummary/lastUsedAt`` to
    /// the time of the call, and sends `factsChanged`.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary with the new time of the last use.
    func markUsed(_ id: ULID) async throws -> SessionSummary

    /// Sends a message to each session that the address names.
    ///
    /// The sender chooses the body of the mail that carries the message:
    ///
    /// - A session sender (``SessionMessageSender/session(_:)``) is delivered
    ///   as ``MailBody/agentMessage(from:content:)``, with the sender
    ///   ``MailSender/session(_:)``.
    /// - A UI sender (``SessionMessageSender/user(clientID:)``) is delivered
    ///   as ``MailBody/userMessage(prompt:options:)``, with the sender
    ///   ``MailSender/user``, because a UI has no session id and the message
    ///   is input of the user.
    ///
    /// ``Mail`` and ``MailBody`` get no field for the details of the sender.
    /// The directory renders a sender header into the content:
    ///
    /// - A session sender gets a header with the title, the agent and the
    ///   folder of the sender session.
    /// - A user sender with no ``OutgoingSessionMessage/sourceSession`` gets
    ///   no header.
    /// - A user sender with a source session gets a header that names the
    ///   source session ("From the user, in <title> (<folder>)"). The body
    ///   stays a user message.
    ///
    /// A recorded target that is not live gets the message in its inbox, for
    /// a session sender and for a user sender. The directory keeps the client
    /// id, the source session, `inReplyTo`, the chain depth and the read flag
    /// in its own record of the message.
    ///
    /// The send does not wait for the target to take the message. The
    /// ``SessionDirectoryEvent/messageDelivered(_:)`` event of the message
    /// comes when the target takes it: at once for an idle target, when the
    /// turn of the message starts for a queued message, and when a host
    /// opens a recorded target. A message that the target does not take at
    /// once gives ``SessionDirectoryEvent/messageQueued(_:)`` at the send,
    /// before the send returns: a `queued` receipt and a `sent` receipt.
    /// A `delivered` receipt and a `started` receipt give no
    /// `messageQueued`.
    ///
    /// - Parameter message: The sender, the address, the text, the reply id
    ///   and the source session of the message.
    /// - Returns: One receipt for each target session.
    func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt]

    /// The messages to `id` that are not read. With `markRead`, they become
    /// read, and a queued message does not start a turn later.
    ///
    /// With `markRead`, the read is how the target takes each message that
    /// is still queued, thus the read sends
    /// ``SessionDirectoryEvent/messageDelivered(_:)`` for it, one time. A
    /// message that the target took before gives no second event.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - markRead: True to mark the messages read.
    /// - Returns: The messages that were not read.
    func inbox(of id: ULID, markRead: Bool) async throws -> [SessionMessage]

    /// One message that the directory delivered to `recipient`, read or not
    /// read, found by its id. A reply finds the sender of the message that
    /// it answers with this lookup, after ``inbox(of:markRead:)`` read it.
    ///
    /// The lookup gives a message only to the session that it went to, thus a
    /// session cannot read the mail of other sessions. It marks nothing read,
    /// and a queued message still starts a turn later.
    ///
    /// - Parameters:
    ///   - id: The id of the message, as ``SessionMessage/id`` holds it.
    ///   - recipient: The session id that the message went to.
    /// - Returns: The message, with its read flag, or `nil` when no message
    ///   has the id or the message went to another session.
    func message(_ id: MailID, to recipient: ULID) async throws -> SessionMessage?

    /// Archives the session `id`: stops a running turn, removes it from the
    /// live list, marks it archived in its facts, and sends `archived`.
    ///
    /// An archive hides the session. It is not final, and it deletes
    /// nothing: the transcripts, the facts, the pin and the inbox stay. Each
    /// message that waits in the queue of the session stays in its inbox as
    /// a message that is not read. A later message to the session goes to
    /// its inbox, and the session stays archived.
    /// ``unarchive(_:by:)`` is the inverse.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - archiver: The session or the user that archives it, for the audit.
    /// - Returns: The summary of the archived session.
    func archive(_ id: ULID, by archiver: SessionMessageSender) async throws -> SessionSummary

    /// Removes the archive mark from the facts of the session `id`. This is
    /// the inverse of ``archive(_:by:)``.
    ///
    /// After the call, the session is a recorded session that is not live,
    /// with the state ``SessionState/idle``. The directory sends
    /// `stateChanged` with `idle`, and then `unarchived`. A host opens the
    /// session as it opens each recorded session, and the session then takes
    /// the messages of its inbox.
    ///
    /// A session that is not archived stays as it is: the call gives its
    /// summary and sends no event. The host tells the caller that the
    /// session was not archived.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - unarchiver: The session or the user that unarchives it, for the
    ///     audit.
    /// - Returns: The summary of the session after the call.
    func unarchive(_ id: ULID, by unarchiver: SessionMessageSender) async throws -> SessionSummary

    /// A new stream for each call. Each stream gets each event after the
    /// call.
    ///
    /// The stream rules (session.md section 7):
    ///
    /// 1. Each call makes one new `AsyncStream` with the
    ///    `.bufferingNewest(256)` policy. A slow reader loses old events, not
    ///    new ones. After a loss, the reader calls
    ///    ``sessions(matching:)`` again.
    /// 2. The events of one session come in order.
    /// 3. The directory sends `started` before the first `stateChanged` of
    ///    that session.
    /// 4. Subagent sessions also give events. Their kind is
    ///    ``SessionKind/subagent``.
    /// 5. An event holds no message text that is longer than the message
    ///    length limit (ROUTER-5).
    /// 6. A message that the target does not take at once gives
    ///    ``SessionDirectoryEvent/messageQueued(_:)`` at the send, and
    ///    ``SessionDirectoryEvent/messageDelivered(_:)`` later, when the
    ///    target takes it.
    ///
    /// - Returns: A stream of the changes in the directory.
    func events() -> AsyncStream<SessionDirectoryEvent>
}

/// The defaults of the pin and the last use, for a directory that does not
/// keep them yet.
extension SessionDirectory {
    /// The default does nothing: it changes no pin and sends no event. It
    /// gives the summary as it is. A directory must implement this method for
    /// pins to work.
    ///
    /// - Parameters:
    ///   - pinned: True to pin the session, false to unpin it. The default
    ///     ignores it.
    ///   - id: The session id.
    /// - Returns: The summary with no change.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` when no session
    ///   has this id.
    public func setPinned(_ pinned: Bool, of id: ULID) async throws -> SessionSummary {
        try await unchangedSummary(of: id)
    }

    /// The default does nothing: it records no use and sends no event. It
    /// gives the summary as it is. A directory must implement this method for
    /// the Recent list to work.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary with no change.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` when no session
    ///   has this id.
    public func markUsed(_ id: ULID) async throws -> SessionSummary {
        try await unchangedSummary(of: id)
    }

    /// The summary of `id`, with no change.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` when no session
    ///   has this id.
    private func unchangedSummary(of id: ULID) async throws -> SessionSummary {
        guard let summary = try await summary(of: id) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        return summary
    }
}

/// The default of the fork, for a directory that cannot fork yet.
extension SessionDirectory {
    /// The default cannot fork: it changes nothing and sends no event. A
    /// directory must implement this method for forks to work.
    ///
    /// - Parameter request: The fork request. The default ignores it.
    /// - Returns: No value. The default always throws.
    /// - Throws: ``SessionDirectoryError/forkUnsupported``.
    public func fork(_ request: SessionForkRequest) async throws -> SessionSummary {
        throw SessionDirectoryError.forkUnsupported
    }
}
