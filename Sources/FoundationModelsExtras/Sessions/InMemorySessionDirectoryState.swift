import Foundation
import ULID

/// The sessions, the messages and the event streams of one
/// ``InMemorySessionDirectory``.
///
/// The directory keeps this value in one lock, and each change runs in it.
/// A change yields its events inside the same lock, thus each stream gets the
/// events in the order of the changes.
struct InMemorySessionDirectoryState {
    /// One session of the directory.
    struct Entry {
        /// The facts and the state of the session.
        var summary: SessionSummary

        /// The chain depth of the message that started the current turn, or
        /// 0 for a turn that a user started. A message from this turn has
        /// this depth plus 1.
        var turnChainDepth = 0

        /// The sends that the current turn made.
        var sendsInTurn = 0
    }

    /// One message that the directory delivered to a session.
    struct Delivery {
        /// The message, with its read flag.
        var message: SessionMessage

        /// True while the message waits for the end of the current turn of
        /// its target, to start the next turn.
        var isQueued: Bool
    }

    /// The tag rule of session.md section 8.2: the longest tag.
    static let tagLengthLimit = 64

    /// The characters other than letters and digits that a tag can hold.
    static let tagPunctuation: Set<Character> = ["-", "_", ":", "."]

    /// The fake launcher, or `nil` when the directory cannot start a session.
    let launcher: InMemorySessionDirectory.Launcher?

    /// The loop guards of each send.
    let loopGuards: InMemorySessionDirectory.LoopGuards

    /// The sessions, by id.
    var entries: [ULID: Entry] = [:]

    /// The session ids, the oldest first.
    private(set) var startOrder: [ULID] = []

    /// The messages to each session, by session id, the oldest first.
    var deliveries: [ULID: [Delivery]] = [:]

    /// The continuation of each open event stream, by subscriber id.
    private var subscribers: [Int: AsyncStream<SessionDirectoryEvent>.Continuation] = [:]

    /// The id of the next event stream.
    private var nextSubscriberID = 0

    /// Makes an empty state.
    ///
    /// - Parameters:
    ///   - launcher: The fake launcher, or `nil`.
    ///   - loopGuards: The loop guards of each send.
    init(launcher: InMemorySessionDirectory.Launcher?, loopGuards: InMemorySessionDirectory.LoopGuards) {
        self.launcher = launcher
        self.loopGuards = loopGuards
    }
}

// MARK: - Sessions

extension InMemorySessionDirectoryState {
    /// The entry of a session.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The entry.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` when no session
    ///   has the id.
    func entry(_ id: ULID) throws -> Entry {
        guard let entry = entries[id] else { throw SessionDirectoryError.unknownSession(id) }
        return entry
    }

    /// Starts a new root session, sends `started`, and starts its first
    /// turn, a user turn.
    ///
    /// - Parameters:
    ///   - request: The start request.
    ///   - now: The time of the start.
    /// - Returns: The summary of the new session.
    /// - Throws: The errors of ``SessionDirectory/start(_:)``.
    mutating func start(_ request: SessionStartRequest, at now: Date) throws -> SessionSummary {
        let id = try launch(request, at: now)
        beginTurn(of: id, chainDepth: 0, at: now)
        return try entry(id).summary
    }

    /// Resolves a start request through the launcher, adds the idle
    /// session, and sends `started`.
    ///
    /// - Parameters:
    ///   - request: The start request.
    ///   - now: The time of the start.
    /// - Returns: The id of the new session.
    /// - Throws: ``SessionDirectoryError/noLauncher``, the errors of the
    ///   launcher, and ``SessionDirectoryError/invalidTag(_:)``.
    mutating func launch(_ request: SessionStartRequest, at now: Date) throws -> ULID {
        guard let launcher else { throw SessionDirectoryError.noLauncher }
        try Self.validate(request.tags)
        let summary = SessionSummary(
            id: ULID(),
            agentID: try launcher.resolveAgent(request.agentID),
            workingDirectory: try resolveFolder(of: request, launcher: launcher),
            title: request.title,
            tags: request.tags,
            kind: .root,
            state: .idle,
            startedBy: request.startedBy,
            origin: request.origin,
            createdAt: now,
            updatedAt: now,
            isLive: true)
        insert(summary, requestedByClient: request.requestedByClient)
        return summary.id
    }

    /// Adds a session that a test made, as the Router registers a vended
    /// session: a live session sends `started` while it is idle, then
    /// `stateChanged` to its own state. A session that is not live sends no
    /// event.
    ///
    /// - Parameters:
    ///   - summary: The summary of the session.
    ///   - now: The time of the registration.
    mutating func register(_ summary: SessionSummary, at now: Date) {
        guard summary.isLive else {
            insert(summary, requestedByClient: nil)
            return
        }
        var idle = summary
        idle.state = .idle
        insert(idle, requestedByClient: nil)
        switch summary.state {
        case .idle:
            break
        case .working:
            beginTurn(of: summary.id, chainDepth: 0, at: now)
        case .needsInput, .archived:
            changeState(of: summary.id, to: summary.state, lastSummary: nil, at: now)
        }
    }

    /// Adds a session, or replaces the session with the same id, and sends
    /// `started` when it is live.
    ///
    /// - Parameters:
    ///   - summary: The summary of the session.
    ///   - requestedByClient: The UI client that asked for the start.
    private mutating func insert(_ summary: SessionSummary, requestedByClient: String?) {
        if entries[summary.id] == nil {
            startOrder.append(summary.id)
        }
        entries[summary.id] = Entry(summary: summary)
        guard summary.isLive else { return }
        emit(.started(summary, requestedByClient: requestedByClient))
    }

    /// The summaries of the sessions that match the query, the newest first,
    /// at most ``SessionQuery/limit`` of them.
    ///
    /// - Parameter query: The filter.
    /// - Returns: The matching summaries.
    func summaries(matching query: SessionQuery) -> [SessionSummary] {
        Array(
            startOrder.reversed().lazy
                .compactMap { entries[$0]?.summary }
                .filter { Self.summary($0, matches: query) }
                .prefix(query.limit))
    }

    /// True when the summary matches each field of the query that is not nil.
    ///
    /// - Parameters:
    ///   - summary: A summary.
    ///   - query: The filter.
    /// - Returns: True for a match.
    private static func summary(_ summary: SessionSummary, matches query: SessionQuery) -> Bool {
        let checks: [Bool] = [
            query.includesRecorded || summary.isLive,
            query.workingDirectory.map { isSameFolder($0, summary.workingDirectory) } ?? true,
            query.tag.map(summary.tags.contains) ?? true,
            accepts(query.agentID, summary.agentID),
            accepts(query.kind, summary.kind),
            accepts(query.state, summary.state),
            accepts(query.parentID, summary.parentID),
            accepts(query.startedBy, summary.startedBy),
        ]
        return !checks.contains(false)
    }

    /// True when a query field is nil, or equals the value of the summary.
    ///
    /// - Parameters:
    ///   - wanted: The field of the query.
    ///   - actual: The value of the summary.
    /// - Returns: True for a match.
    private static func accepts<Value: Equatable>(_ wanted: Value?, _ actual: Value?) -> Bool {
        wanted.map { $0 == actual } ?? true
    }

    /// True when two URLs name the same folder, after the symbolic links
    /// are resolved and a trailing `/` is removed (session.md section 9).
    ///
    /// - Parameters:
    ///   - first: A folder.
    ///   - second: An other folder.
    /// - Returns: True for the same folder.
    static func isSameFolder(_ first: URL, _ second: URL) -> Bool {
        first.resolvingSymlinksInPath().standardizedFileURL.path
            == second.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Changes the facts of a session, and sends `factsChanged` when they
    /// changed.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - now: The time of the change.
    ///   - change: The change of the summary.
    /// - Returns: The summary after the change.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    mutating func changeFacts(
        of id: ULID,
        at now: Date,
        _ change: (inout SessionSummary) -> Void
    ) throws -> SessionSummary {
        let before = try entry(id).summary
        var after = before
        change(&after)
        guard after != before else { return before }
        after.updatedAt = now
        entries[id]?.summary = after
        emit(.factsChanged(after))
        return after
    }

    /// Archives a session: its state becomes archived, it leaves the live
    /// list, and the directory sends `archived`. A session that is archived
    /// already stays as it is, with no event.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - now: The time of the archive.
    /// - Returns: The summary of the archived session.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    mutating func archive(_ id: ULID, at now: Date) throws -> SessionSummary {
        var summary = try entry(id).summary
        guard summary.state != .archived else { return summary }
        summary.state = .archived
        summary.isLive = false
        summary.updatedAt = now
        entries[id]?.summary = summary
        emit(.archived(id: id))
        return summary
    }

    /// The working folder of a start: the folder of the request, else the
    /// folder of `startedBy`, else the folder of the launcher.
    ///
    /// - Parameters:
    ///   - request: The start request.
    ///   - launcher: The fake launcher.
    /// - Returns: The working folder of the new session.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` when
    ///   `startedBy` names no session.
    private func resolveFolder(
        of request: SessionStartRequest,
        launcher: InMemorySessionDirectory.Launcher
    ) throws -> URL {
        if let folder = request.workingDirectory { return folder }
        guard let starter = request.startedBy else { return launcher.defaultWorkingDirectory }
        return try entry(starter).summary.workingDirectory
    }

    /// Checks each tag against the tag rule of session.md section 8.2: 1 to
    /// 64 characters, letters, digits, `-`, `_`, `:` and `.`.
    ///
    /// - Parameter tags: The tags to check.
    /// - Throws: ``SessionDirectoryError/invalidTag(_:)`` for the first tag
    ///   outside the rule, in name order.
    static func validate(_ tags: Set<String>) throws {
        for tag in tags.sorted() where !isValid(tag) {
            throw SessionDirectoryError.invalidTag(tag)
        }
    }

    /// True when `tag` follows the tag rule.
    ///
    /// - Parameter tag: The tag to check.
    /// - Returns: True for 1 to 64 letters, digits, `-`, `_`, `:` and `.`.
    private static func isValid(_ tag: String) -> Bool {
        (1...tagLengthLimit).contains(tag.count)
            && tag.allSatisfy { $0.isLetter || $0.isASCII && $0.isNumber || tagPunctuation.contains($0) }
    }
}

// MARK: - Turns

extension InMemorySessionDirectoryState {
    /// Starts a turn of a session: the state becomes working, and the sends
    /// of the turn count from 0.
    ///
    /// - Parameters:
    ///   - id: The session id. The session exists.
    ///   - chainDepth: The depth of the message that starts the turn, or 0
    ///     for a user turn.
    ///   - now: The time of the change.
    mutating func beginTurn(of id: ULID, chainDepth: Int, at now: Date) {
        entries[id]?.turnChainDepth = chainDepth
        entries[id]?.sendsInTurn = 0
        changeState(of: id, to: .working, lastSummary: nil, at: now)
    }

    /// Starts a turn that a user started, with chain depth 0. An archived
    /// session stays as it is.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - now: The time of the change.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    mutating func startUserTurn(of id: ULID, at now: Date) throws {
        guard try isActive(id) else { return }
        beginTurn(of: id, chainDepth: 0, at: now)
    }

    /// Makes the current turn of a session wait for an answer: the state
    /// becomes needsInput. An archived session stays as it is.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - now: The time of the change.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    mutating func requestInput(of id: ULID, at now: Date) throws {
        guard try isActive(id) else { return }
        changeState(of: id, to: .needsInput, lastSummary: nil, at: now)
    }

    /// Ends the current turn of a session: the state becomes idle, with the
    /// last summary. Then the queued messages that are not read start the
    /// next turn, at the deepest chain depth among them. An archived session
    /// stays as it is.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - lastSummary: The last final message of the turn.
    ///   - now: The time of the change.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    mutating func finishTurn(of id: ULID, lastSummary: String?, at now: Date) throws {
        guard try isActive(id) else { return }
        changeState(of: id, to: .idle, lastSummary: lastSummary, at: now)
        let queuedDepths = deliveries[id, default: []].filter(\.isQueued).map(\.message.chainDepth)
        guard let chainDepth = queuedDepths.max() else { return }
        updateDeliveries(of: id) { $0.isQueued = false }
        beginTurn(of: id, chainDepth: chainDepth, at: now)
    }

    /// True when the session is not archived, thus a turn can change it.
    ///
    /// - Parameter id: The session id.
    /// - Returns: False for an archived session.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)``.
    private func isActive(_ id: ULID) throws -> Bool {
        try entry(id).summary.state != .archived
    }

    /// Changes each message to a session.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - change: The change of one message.
    mutating func updateDeliveries(of id: ULID, _ change: (inout Delivery) -> Void) {
        guard var messages = deliveries[id] else { return }
        for index in messages.indices {
            change(&messages[index])
        }
        deliveries[id] = messages
    }

    /// Sets the state of a session and sends `stateChanged`.
    ///
    /// - Parameters:
    ///   - id: The session id. The session exists.
    ///   - state: The new state.
    ///   - lastSummary: The new last summary, for the idle state.
    ///   - now: The time of the change.
    mutating func changeState(of id: ULID, to state: SessionState, lastSummary: String?, at now: Date) {
        entries[id]?.summary.state = state
        entries[id]?.summary.updatedAt = now
        if state == .idle {
            entries[id]?.summary.lastSummary = lastSummary
        }
        emit(.stateChanged(id: id, state: state, lastSummary: lastSummary))
    }
}

// MARK: - Events

extension InMemorySessionDirectoryState {
    /// Adds an event stream.
    ///
    /// - Parameter continuation: The continuation of the new stream.
    /// - Returns: The subscriber id, for ``unsubscribe(_:)``.
    mutating func subscribe(_ continuation: AsyncStream<SessionDirectoryEvent>.Continuation) -> Int {
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        return id
    }

    /// Removes an event stream that ended.
    ///
    /// - Parameter id: The subscriber id.
    mutating func unsubscribe(_ id: Int) {
        subscribers[id] = nil
    }

    /// Removes each event stream, and gives their continuations, so that the
    /// caller finishes them outside the lock.
    ///
    /// - Returns: The continuation of each open stream.
    mutating func removeSubscribers() -> [AsyncStream<SessionDirectoryEvent>.Continuation] {
        defer { subscribers = [:] }
        return Array(subscribers.values)
    }

    /// Gives an event to each open stream.
    ///
    /// - Parameter event: The event.
    func emit(_ event: SessionDirectoryEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }
}
