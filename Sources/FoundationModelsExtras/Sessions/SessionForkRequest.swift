import ULID

/// A request to fork a session: a new top-level session of kind
/// ``SessionKind/fork``, in the folder of its source, with the agent of its
/// source and a copy of its history up to a cut.
public struct SessionForkRequest: Sendable, Codable, Equatable {
    /// The id of the session to fork.
    public var sourceID: ULID

    /// The point in the history of the source where the fork cuts it.
    public var cut: SessionForkCut

    /// The prompt that starts the first turn of the fork, or `nil` to start
    /// no turn.
    public var firstPrompt: String?

    /// The UI client that asked for the fork, for the tab rule. Nil for a
    /// fork that a session asked for.
    public var requestedByClient: String?

    /// The session or the user that asked for the fork, for the audit.
    public var forker: SessionMessageSender

    /// Makes a fork request.
    ///
    /// - Parameters:
    ///   - sourceID: The id of the session to fork.
    ///   - cut: The point in the history of the source where the fork cuts
    ///     it.
    ///   - firstPrompt: The prompt that starts the first turn of the fork.
    ///     The default is `nil`: the fork starts no turn.
    ///   - requestedByClient: The UI client that asks for the fork. The
    ///     default is `nil`.
    ///   - forker: The session or the user that asks for the fork.
    public init(
        sourceID: ULID,
        cut: SessionForkCut,
        firstPrompt: String? = nil,
        requestedByClient: String? = nil,
        forker: SessionMessageSender
    ) {
        self.sourceID = sourceID
        self.cut = cut
        self.firstPrompt = firstPrompt
        self.requestedByClient = requestedByClient
        self.forker = forker
    }
}
