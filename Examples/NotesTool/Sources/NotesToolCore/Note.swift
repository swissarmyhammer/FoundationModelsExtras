/// A single note, as stored by `NotesStore` and returned by every notes
/// operation.
internal struct Note: Encodable, Sendable, Equatable {
    /// The note's store-assigned id (e.g. `"note-1"`).
    internal let id: String

    /// The note's title.
    internal let title: String

    /// The note's Markdown body, if any.
    internal let body: String?

    /// Tags attached to the note, in the order they were added.
    internal var tags: [String]
}
