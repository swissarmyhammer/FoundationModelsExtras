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
    /// - Parameters:
    ///   - id: The session id.
    ///   - markRead: True to mark the messages read.
    /// - Returns: The messages that were not read, the oldest first.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    mutating func inbox(of id: ULID, markRead: Bool) throws -> [SessionMessage] {
        _ = try entry(id)
        let unread = deliveries[id, default: []].map(\.message).filter { !$0.isRead }
        if markRead {
            updateDeliveries(of: id) { delivery in
                delivery.message.isRead = true
                delivery.isQueued = false
            }
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
            guard let target = newestLiveRoot(agentID: nil, in: folder) else {
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

    /// Delivers the message to the newest live root session of the agent,
    /// or starts one with origin ``SessionDirectoryOrigin/message``.
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
        let wantedFolder = folder ?? workingFolder(of: message.from)
        if let target = newestLiveRoot(agentID: agentID, in: wantedFolder) {
            return deliver(message, chainDepth: chainDepth, to: target, at: now)
        }
        let request = SessionStartRequest(
            agentID: agentID,
            workingDirectory: wantedFolder,
            firstMessage: message.text,
            startedBy: Self.sessionID(of: message.from),
            origin: .message)
        let id = try launch(request, at: now)
        let delivered = record(message, chainDepth: chainDepth, to: id, isQueued: false, at: now)
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
    /// archived target refuses it, a recorded target is restored first, an
    /// idle target starts a turn, and a working target queues it.
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
        if !target.isLive {
            guard launcher != nil else { return Self.refused(.noLauncher, target: target.id) }
            restore(target.id)
        }
        let isIdle = target.state == .idle
        let delivered = record(message, chainDepth: chainDepth, to: target.id, isQueued: !isIdle, at: now)
        guard isIdle else {
            return SessionSendReceipt(messageID: delivered.id, target: target.id, outcome: .queued)
        }
        beginTurn(of: target.id, chainDepth: chainDepth, at: now)
        return SessionSendReceipt(messageID: delivered.id, target: target.id, outcome: .delivered)
    }

    /// Makes a recorded session live again, and sends `started`.
    ///
    /// - Parameter id: The session id. The session exists.
    private mutating func restore(_ id: ULID) {
        entries[id]?.summary.isLive = true
        guard let summary = entries[id]?.summary else { return }
        emit(.started(summary, requestedByClient: nil))
    }

    /// Records a message to a session, and sends `messageDelivered`.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - id: The target session id.
    ///   - isQueued: True when the message waits for the end of the turn.
    ///   - now: The time of the delivery.
    /// - Returns: The delivered message.
    private mutating func record(
        _ message: OutgoingSessionMessage,
        chainDepth: Int,
        to id: ULID,
        isQueued: Bool,
        at now: Date
    ) -> SessionMessage {
        let delivered = SessionMessage(
            id: MailID(),
            from: message.from,
            to: id,
            text: message.text,
            inReplyTo: message.inReplyTo,
            sentAt: now,
            chainDepth: chainDepth)
        deliveries[id, default: []].append(Delivery(message: delivered, isQueued: isQueued))
        emit(.messageDelivered(delivered))
        return delivered
    }

    /// The newest live root session, of the agent when it is given, in the
    /// folder when it is given.
    ///
    /// - Parameters:
    ///   - agentID: The agent id, or `nil` for any agent.
    ///   - folder: The folder, or `nil` for any folder.
    /// - Returns: The summary of the session, or `nil` when none matches.
    private func newestLiveRoot(agentID: String?, in folder: URL?) -> SessionSummary? {
        summaries(matching: SessionQuery(workingDirectory: folder, agentID: agentID, kind: .root, limit: 1)).first
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
