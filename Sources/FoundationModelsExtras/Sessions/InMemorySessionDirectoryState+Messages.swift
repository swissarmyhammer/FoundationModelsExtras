import Foundation
import ULID

/// The sends, the inbox and the message lookup of the test double: the
/// address rules of session.md section 9, the delivery rules of section 10.2
/// and the loop guards of section 10.3.
extension InMemorySessionDirectoryState {
    /// The reason of a `refused` receipt.
    typealias Refusal = InMemorySessionDirectory.Refusal

    /// Applies the loop guards, resolves the address, and delivers the
    /// message to each target.
    ///
    /// - Parameters:
    ///   - message: The message to send.
    ///   - now: The time of the send.
    /// - Returns: One receipt for each target.
    /// - Throws: ``SessionDirectoryError/messageTooLong(limit:)``,
    ///   ``SessionDirectoryError/invalidTag(_:)``,
    ///   ``SessionDirectoryError/unknownSession(_:)`` for an unknown sender or
    ///   target, and the start errors of an agent address.
    mutating func send(_ message: OutgoingSessionMessage, at now: Date) throws -> [SessionSendReceipt] {
        guard message.text.utf8.count <= loopGuards.messageLengthLimit else {
            throw SessionDirectoryError.messageTooLong(limit: loopGuards.messageLengthLimit)
        }
        if case .tag(let tag) = message.to {
            try Self.validate([tag])
        }
        let chainDepth = try chainDepth(of: message.from)
        if let refusal = countSend(from: message.from) ?? checkChainDepth(chainDepth) {
            return [Self.refused(refusal)]
        }
        return try route(message, chainDepth: chainDepth, at: now)
    }

    /// The messages to a session that are not read, and with `markRead`,
    /// marks them read, thus no queued message starts a turn later.
    ///
    /// With `markRead`, the read is how the target takes each queued
    /// message, thus the read sends `messageDelivered` for each of them, one
    /// time, in the order of the sends. A message that the target took
    /// before gives no second event.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - markRead: True to mark the messages read.
    /// - Returns: The messages that were not read, the oldest first.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    mutating func inbox(of id: ULID, markRead: Bool) throws -> [SessionMessage] {
        _ = try entry(id)
        let unread = deliveries[id, default: []].map(\.message).filter { !$0.isRead }
        if markRead {
            _ = takeQueuedMessages(of: id)
            updateDeliveries(of: id) { $0.message.isRead = true }
        }
        return unread
    }

    /// One message to a session, read or not read, found by its id. It
    /// marks nothing read.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - recipient: The session id that the message went to.
    /// - Returns: The message, or `nil` when no message to `recipient` has
    ///   the id.
    func message(_ id: MailID, to recipient: ULID) -> SessionMessage? {
        deliveries[recipient]?.first { $0.message.id == id }?.message
    }

    /// Delivers the message to each session that the address names.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - now: The time of the send.
    /// - Returns: One receipt for each target.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` for an unknown
    ///   target, and the start errors of an agent address.
    private mutating func route(
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        at now: Date
    ) throws -> [SessionSendReceipt] {
        switch message.to {
        case .session(let id):
            return [deliver(message, chainDepth: chainDepth, to: try entry(id).summary, at: now)]
        case .agent(let agentID, let folder):
            return [try sendToAgent(agentID, in: folder, message, chainDepth: chainDepth, at: now)]
        case .folder(let folder):
            guard let target = newestLiveRoot(in: folder) else {
                return [Self.refused(.noSessionInTheFolder)]
            }
            return [deliver(message, chainDepth: chainDepth, to: target, at: now)]
        case .tag(let tag):
            return sendToTag(tag, message, chainDepth: chainDepth, at: now)
        }
    }

    /// The chain depth of a message from a sender: 1 from a UI, else the
    /// depth of the message that started the turn of the sender, plus 1.
    ///
    /// - Parameter sender: The sender.
    /// - Returns: The chain depth.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` for an unknown
    ///   session sender.
    private func chainDepth(of sender: SessionMessageSender) throws -> Int {
        switch sender {
        case .session(let id):
            try entry(id).turnChainDepth + 1
        case .user:
            1
        }
    }

    /// Counts a send of the current turn of a session sender.
    ///
    /// - Parameter sender: The sender.
    /// - Returns: ``Refusal/tooManySends`` when the turn made the most sends
    ///   that one turn can make, else `nil`.
    private mutating func countSend(from sender: SessionMessageSender) -> Refusal? {
        guard case .session(let id) = sender else { return nil }
        guard let sends = entries[id]?.sendsInTurn, sends < loopGuards.sendsPerTurnLimit else {
            return .tooManySends
        }
        entries[id]?.sendsInTurn = sends + 1
        return nil
    }

    /// Checks the chain depth against its limit.
    ///
    /// - Parameter chainDepth: The chain depth of a message.
    /// - Returns: ``Refusal/chainTooDeep`` above the limit, else `nil`.
    private func checkChainDepth(_ chainDepth: Int) -> Refusal? {
        chainDepth > loopGuards.chainDepthLimit ? .chainTooDeep : nil
    }

    /// Starts a new root session of the agent with origin
    /// ``SessionDirectoryOrigin/message``, and delivers the message to it.
    /// Each send starts a new session, also when the agent has a live root
    /// session in the folder.
    ///
    /// - Parameters:
    ///   - agentID: The agent id of the address.
    ///   - folder: The folder of the address, else the folder of the sender.
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - now: The time of the send.
    /// - Returns: The receipt.
    /// - Throws: The start errors: ``SessionDirectoryError/noLauncher`` and
    ///   ``SessionDirectoryError/unknownAgent(_:nearNames:)``.
    private mutating func sendToAgent(
        _ agentID: String,
        in folder: URL?,
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        at now: Date
    ) throws -> SessionSendReceipt {
        let request = SessionStartRequest(
            agentID: agentID,
            workingDirectory: folder ?? workingFolder(of: message.from),
            firstMessage: message.text,
            startedBy: Self.sessionID(of: message.from),
            origin: .message)
        let id = try launch(request, at: now)
        let delivered = record(message, chainDepth: chainDepth, to: id, at: now)
        beginTurn(of: id, chainDepth: chainDepth, at: now)
        return SessionSendReceipt(messageID: delivered.id, target: id, outcome: .started)
    }

    /// Delivers the message to each live session with the tag, but not the
    /// sender, the oldest first, up to the target limit. The other targets
    /// get a `refused` receipt.
    ///
    /// - Parameters:
    ///   - tag: The tag of the address.
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - now: The time of the send.
    /// - Returns: One receipt for each target, or one `refused` receipt when
    ///   no session matches.
    private mutating func sendToTag(
        _ tag: String,
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        at now: Date
    ) -> [SessionSendReceipt] {
        let sender = Self.sessionID(of: message.from)
        let targets = startOrder.compactMap { entries[$0]?.summary }
            .filter { $0.isLive && $0.tags.contains(tag) && $0.id != sender }
        guard !targets.isEmpty else { return [Self.refused(.noSessionHasTheTag)] }
        let limit = loopGuards.tagTargetLimit
        let delivered = targets.prefix(limit).map { deliver(message, chainDepth: chainDepth, to: $0, at: now) }
        let refused = targets.dropFirst(limit).map { Self.refused(.tooManyTargets, target: $0.id) }
        return delivered + refused
    }

    /// Delivers the message to one session (session.md section 10.2): an
    /// archived target refuses it, a recorded target gets it in its inbox, an
    /// idle target starts a turn, and a working target queues it.
    ///
    /// `messageDelivered` tells that the target took the message. An idle
    /// target takes it at once, thus the event comes before the state of
    /// its turn. A working target takes it later, thus the send sends
    /// `messageQueued`, and `messageDelivered` comes when the turn of the
    /// message starts (``finishTurn(of:lastSummary:at:)``), or when an inbox
    /// read marks the message read (``inbox(of:markRead:)``).
    ///
    /// A recorded target that is not live gets the message in its inbox, for
    /// a session sender and for a user sender, also when the directory has no
    /// launcher. The directory does not restore the session and starts no
    /// turn. The receipt is `sent`, and the directory sends `messageQueued`
    /// and no `messageDelivered`: a recorded target takes the message only
    /// when a host opens it.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - target: The summary of the target session.
    ///   - now: The time of the send.
    /// - Returns: The receipt.
    private mutating func deliver(
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        to target: SessionSummary,
        at now: Date
    ) -> SessionSendReceipt {
        guard target.state != .archived else { return Self.refused(.archived, target: target.id) }
        guard target.isLive else {
            let stored = enqueue(message, chainDepth: chainDepth, to: target.id, isQueued: false, at: now)
            return SessionSendReceipt(messageID: stored.id, target: target.id, outcome: .sent)
        }
        guard target.state == .idle else {
            let queued = enqueue(message, chainDepth: chainDepth, to: target.id, isQueued: true, at: now)
            return SessionSendReceipt(messageID: queued.id, target: target.id, outcome: .queued)
        }
        let delivered = record(message, chainDepth: chainDepth, to: target.id, at: now)
        beginTurn(of: target.id, chainDepth: chainDepth, at: now)
        return SessionSendReceipt(messageID: delivered.id, target: target.id, outcome: .delivered)
    }

    /// Records a message that a live session takes now, and sends
    /// `messageDelivered`. The caller starts the turn of the message next.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - id: The target session id.
    ///   - now: The time of the delivery.
    /// - Returns: The delivered message.
    private mutating func record(
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        to id: ULID,
        at now: Date
    ) -> SessionMessage {
        let delivered = store(message, chainDepth: chainDepth, to: id, isQueued: false, at: now)
        emit(.messageDelivered(delivered))
        return delivered
    }

    /// Puts a message that the target does not take now in the inbox of a
    /// session, and sends `messageQueued`. The target takes the message
    /// later, and then the directory sends `messageDelivered`.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - id: The target session id.
    ///   - isQueued: True when the message waits for the end of the turn.
    ///   - now: The time of the send.
    /// - Returns: The stored message.
    private mutating func enqueue(
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        to id: ULID,
        isQueued: Bool,
        at now: Date
    ) -> SessionMessage {
        let stored = store(message, chainDepth: chainDepth, to: id, isQueued: isQueued, at: now)
        emit(.messageQueued(stored))
        return stored
    }

    /// Puts a message in the inbox of a session, and sends no event. The
    /// caller sends the event of the message.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - id: The target session id.
    ///   - isQueued: True when the message waits for the end of the turn.
    ///   - now: The time of the send.
    /// - Returns: The stored message.
    private mutating func store(
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        to id: ULID,
        isQueued: Bool,
        at now: Date
    ) -> SessionMessage {
        let stored = SessionMessage(
            id: MailID(),
            from: message.from,
            to: id,
            text: message.text,
            inReplyTo: message.inReplyTo,
            sourceSession: message.sourceSession,
            sentAt: now,
            chainDepth: chainDepth)
        deliveries[id, default: []].append(Delivery(message: stored, isQueued: isQueued))
        return stored
    }

    /// The newest live root session in the folder, of any agent.
    ///
    /// - Parameter folder: The folder.
    /// - Returns: The summary of the session, or `nil` when none matches.
    private func newestLiveRoot(in folder: URL) -> SessionSummary? {
        summaries(matching: SessionQuery(workingDirectory: folder, kind: .root, limit: 1)).first
    }

    /// The working folder of a session sender, or `nil` for a UI sender.
    ///
    /// - Parameter sender: The sender.
    /// - Returns: The folder of the sender session.
    private func workingFolder(of sender: SessionMessageSender) -> URL? {
        Self.sessionID(of: sender).flatMap { entries[$0]?.summary.workingDirectory }
    }

    /// The session id of a session sender, or `nil` for a UI sender.
    ///
    /// - Parameter sender: The sender.
    /// - Returns: The session id.
    private static func sessionID(of sender: SessionMessageSender) -> ULID? {
        if case .session(let id) = sender { id } else { nil }
    }

    /// A `refused` receipt.
    ///
    /// - Parameters:
    ///   - refusal: The reason.
    ///   - target: The target session, or `nil` when no session matched.
    /// - Returns: The receipt, with no message id.
    private static func refused(_ refusal: Refusal, target: ULID? = nil) -> SessionSendReceipt {
        SessionSendReceipt(target: target, outcome: .refused, reason: refusal.rawValue)
    }
}
