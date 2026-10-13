/// The work that caused one output event of a session.
///
/// Each output event has one origin. A caller uses it to find the events
/// of its mail or of its signal.
public enum Origin: Sendable, Codable, Hashable {
    /// An answer to a batch of mail. One submission can carry more than one
    /// mail, thus the value is a set of ids.
    case mail(Set<MailID>)

    /// Work that a signal started, for example a compaction.
    case signal(SignalID)

    /// Session work that no mail and no signal started. Errors of this
    /// kind (for example a model load failure) also have this origin.
    case system
}
