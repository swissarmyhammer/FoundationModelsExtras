/// The event of a ``ChangeLog`` whose changes are ids: the ids that one change added, changed, and removed.
///
/// One event can hold many ids, for example one reload of a catalog.
public struct ChangedIDs: Hashable, Sendable {
    /// The ids that the change added.
    public let added: [String]

    /// The ids that the change changed.
    public let changed: [String]

    /// The ids that the change removed.
    public let removed: [String]

    /// Makes the event of one change.
    ///
    /// - Parameters:
    ///   - added: The ids that the change added.
    ///   - changed: The ids that the change changed.
    ///   - removed: The ids that the change removed.
    public init(added: [String] = [], changed: [String] = [], removed: [String] = []) {
        self.added = added
        self.changed = changed
        self.removed = removed
    }
}

/// One change of a `changes` subscription in the shared shape
/// `<Noun>Change { cursor: String!, at: DateTime!, added: [ID!]!, changed: [ID!]!, removed: [ID!]! }`.
///
/// An endpoint maps it with Graphiti as its own `<Noun>Change` type, for example
/// `Type(IDChange.self, as: "NoteChange")` with one `Field` for each property, and resolves each event of the
/// subscription with ``init(_:)``.
public struct IDChange: Hashable, Sendable {
    /// The cursor that resumes the subscription after this change.
    public let cursor: String

    /// The time of the change.
    public let at: DateTime

    /// The ids that the change added.
    public let added: [String]

    /// The ids that the change changed.
    public let changed: [String]

    /// The ids that the change removed.
    public let removed: [String]

    /// Makes the change of one entry of a ``ChangeLog``.
    ///
    /// - Parameter entry: The entry, which gives the cursor, the time, and the ids.
    public init(_ entry: ChangeLogEntry<ChangedIDs>) {
        cursor = entry.cursor
        at = DateTime(entry.at)
        added = entry.event.added
        changed = entry.event.changed
        removed = entry.event.removed
    }
}
