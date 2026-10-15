/// Tells if a user can answer the questions of a session.
///
/// The host that makes a session sets this value one time, on the
/// ``RunPlane`` of the session. It does not change for the life of the
/// session.
public enum UserPresence: Sendable, Equatable {
    /// A user can answer questions. A question goes to the user, and the run
    /// that asked it waits for the answer.
    case interactive

    /// No user is present. Each question ends at once with a cancel that
    /// gives ``RunPlane/noUserPresentReason``. The question does not go to
    /// the sink, and nothing waits for an answer.
    case headless
}
