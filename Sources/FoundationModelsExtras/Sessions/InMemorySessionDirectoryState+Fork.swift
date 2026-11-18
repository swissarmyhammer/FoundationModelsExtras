import Foundation
import ULID

// MARK: - Forks

extension InMemorySessionDirectoryState {
    /// Forks a session: adds an idle, live session of kind `fork`, in the
    /// folder of the source, with the agent of the source, and sends
    /// `started`. A first prompt then starts a user turn, as the first
    /// message of a start does. The directory records the request of the
    /// fork. It copies no history, because it keeps none.
    ///
    /// - Parameters:
    ///   - request: The fork request.
    ///   - now: The time of the fork.
    /// - Returns: The summary of the fork.
    /// - Throws: ``SessionDirectoryError/unknownSession(_:)`` for an unknown
    ///   source, ``SessionDirectoryError/archivedSession(_:)`` for an
    ///   archived source, and ``SessionDirectoryError/forkCutOutOfRange(_:)``
    ///   for a cut outside the rule of ``check(_:of:)``.
    mutating func fork(_ request: SessionForkRequest, at now: Date) throws -> SessionSummary {
        let source = try entry(request.sourceID).summary
        guard source.state != .archived else { throw SessionDirectoryError.archivedSession(source.id) }
        try Self.check(request.cut, of: source, turnCount: try entry(source.id).turnCount)
        let fork = SessionSummary(
            id: ULID(),
            agentID: source.agentID,
            agentName: source.agentName,
            workingDirectory: source.workingDirectory,
            title: SessionName.fork(sourceName: source.slug, usedNames: usedNames(in: source.workingDirectory)),
            tags: [],
            kind: .fork,
            state: .idle,
            parentID: source.id,
            origin: .fork,
            createdAt: now,
            updatedAt: now,
            isLive: true)
        forkRequests[fork.id] = request
        insert(fork, requestedByClient: request.requestedByClient)
        if request.firstPrompt != nil {
            beginTurn(of: fork.id, chainDepth: 0, at: now)
        }
        return try entry(fork.id).summary
    }

    /// Checks the cut of a fork. The test double keeps no history, thus the
    /// rule is simple:
    ///
    /// - ``SessionForkCut/lastCompletedTurn`` is always in range.
    /// - ``SessionForkCut/callingToolCall`` is in range only when the source
    ///   works, because only a turn that runs can call a tool.
    /// - ``SessionForkCut/historyPosition(_:)`` is in range when the position
    ///   is 0 or more.
    /// - ``SessionForkCut/beforeTurn(_:)`` is in range when the source started
    ///   the turn with that index. Each turn that the directory starts counts:
    ///   a first message, a delivered message, and a user turn.
    /// - ``SessionForkCut/afterTurn(_:)`` is in range when the source started
    ///   the turn with that index, and the turn is complete. The last turn
    ///   of a source that works or that needs input still runs.
    ///
    /// - Parameters:
    ///   - cut: The cut of the fork.
    ///   - source: The summary of the source session.
    ///   - turnCount: The number of turns that the source started.
    /// - Throws: ``SessionDirectoryError/forkCutOutOfRange(_:)`` for a cut
    ///   that is not in range.
    private static func check(_ cut: SessionForkCut, of source: SessionSummary, turnCount: Int) throws {
        let isInRange: Bool
        switch cut {
        case .lastCompletedTurn:
            isInRange = true
        case .callingToolCall:
            isInRange = source.state == .working
        case .historyPosition(let position):
            isInRange = position >= 0
        case .beforeTurn(let index):
            isInRange = (0..<turnCount).contains(index)
        case .afterTurn(let index):
            let lastTurnRuns = source.state == .working || source.state == .needsInput
            let completeTurns = lastTurnRuns ? turnCount - 1 : turnCount
            isInRange = (0..<max(completeTurns, 0)).contains(index)
        }
        guard isInRange else { throw SessionDirectoryError.forkCutOutOfRange(cut) }
    }
}
