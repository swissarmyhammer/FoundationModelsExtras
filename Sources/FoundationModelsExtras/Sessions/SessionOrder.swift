/// The order of the summaries that ``SessionDirectory/sessions(matching:)``
/// gives.
public enum SessionOrder: String, Sendable, Codable, Equatable, CaseIterable {
    /// The newest start first: ``SessionSummary/createdAt``, the newest
    /// first.
    case newestFirst

    /// The pin order, for the Pinned list: ``SessionSummary/pinnedAt``, the
    /// first pin first. The sessions that are not pinned come after, the
    /// newest start first.
    case pinOrder

    /// The last use first, for the Recent list:
    /// ``SessionSummary/lastUsedAt``, the newest first. The sessions that no
    /// client used come after, the newest start first.
    case lastUsedFirst
}
