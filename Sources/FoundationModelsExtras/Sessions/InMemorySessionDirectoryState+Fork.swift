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
        try Self.check(request.cut, of: source)
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
    ///
    /// - Parameters:
    ///   - cut: The cut of the fork.
    ///   - source: The summary of the source session.
    /// - Throws: ``SessionDirectoryError/forkCutOutOfRange(_:)`` for a cut
    ///   that is not in range.
    private static func check(_ cut: SessionForkCut, of source: SessionSummary) throws {
        let isInRange: Bool
        switch cut {
        case .lastCompletedTurn:
            isInRange = true
        case .callingToolCall:
            isInRange = source.state == .working
        case .historyPosition(let position):
            isInRange = position >= 0
        }
        guard isInRange else { throw SessionDirectoryError.forkCutOutOfRange(cut) }
    }
}
