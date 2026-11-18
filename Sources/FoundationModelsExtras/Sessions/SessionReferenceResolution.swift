/// The result of ``SessionReference/resolve(_:sourceFolder:among:)``.
public enum SessionReferenceResolution: Sendable, Equatable {
    /// The reference names exactly this session.
    case session(SessionSummary)

    /// The reference names two or more sessions. They are in the order of
    /// the summaries that the caller gave.
    case ambiguous([SessionSummary])

    /// The reference names no session. The caller can start an agent.
    case none
}
