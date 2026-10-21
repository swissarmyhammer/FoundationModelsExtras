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
    /// The directory renders a sender header (the title, the agent and the
    /// folder of the session, or "the user") into the content, and keeps the
    /// client id, `inReplyTo`, the chain depth and the read flag in its own
    /// record of the message.
    ///
    /// - Parameter message: The sender, the address, the text and the reply
    ///   id of the message.
    /// - Returns: One receipt for each target session.
    func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt]

    /// The messages to `id` that are not read. With `markRead`, they become
    /// read, and a queued message does not start a turn later.
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

    /// Ends the session `id` (D68): stops a running turn, removes it from the
    /// live list, marks it archived in its facts, and sends `archived`.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - archiver: The session or the user that archives it, for the audit.
    /// - Returns: The summary of the archived session.
    func archive(_ id: ULID, by archiver: SessionMessageSender) async throws -> SessionSummary

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
    ///
    /// - Returns: A stream of the changes in the directory.
    func events() -> AsyncStream<SessionDirectoryEvent>
}
