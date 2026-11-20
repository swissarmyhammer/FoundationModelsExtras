extension InMemorySessionDirectory {
    /// The reason of each `refused` receipt of the test double. The raw value
    /// is the text of ``SessionSendReceipt/reason``.
    public enum Refusal: String, Sendable, CaseIterable {
        /// No live session other than the sender has the tag of a tag
        /// address.
        case noSessionHasTheTag = "No live session has the tag."

        /// The tag send reached its target limit before this target.
        case tooManyTargets = "The tag send reached its target limit."

        /// The message is deeper in its chain than the limit.
        case chainTooDeep = "The message chain is deeper than the limit."

        /// The turn of the sender made the most sends that one turn can make.
        case tooManySends = "The turn sent the most messages that one turn can send."
    }
}
