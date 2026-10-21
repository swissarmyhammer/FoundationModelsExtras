extension InMemorySessionDirectory {
    /// The reason of each `refused` receipt of the test double. The raw value
    /// is the text of ``SessionSendReceipt/reason``.
    public enum Refusal: String, Sendable, CaseIterable {
        /// The target is archived (session.md section 10.2).
        case archived

        /// No live root session works in the folder of a folder address
        /// (session.md section 9).
        case noSessionInTheFolder = "Name an agent: @agent:/path."

        /// No live session other than the sender has the tag of a tag
        /// address.
        case noSessionHasTheTag = "No live session has the tag."

        /// The tag send reached its target limit before this target.
        case tooManyTargets = "The tag send reached its target limit."

        /// The message is deeper in its chain than the limit.
        case chainTooDeep = "The message chain is deeper than the limit."

        /// The turn of the sender made the most sends that one turn can make.
        case tooManySends = "The turn sent the most messages that one turn can send."

        /// The target is recorded and not live, and the directory has no
        /// launcher to restore it.
        case noLauncher = "The directory has no launcher to restore the session."
    }
}
