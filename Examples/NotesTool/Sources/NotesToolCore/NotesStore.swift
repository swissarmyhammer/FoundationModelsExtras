/// An in-memory note store shared by every notes operation dispatched
/// against the same `NotesContext`.
///
/// An `actor` rather than a plain class or struct: `NotesContext` (and
/// therefore `NotesStore`) is captured by `OperationTool.call(arguments:)`,
/// which per `Tool.call`'s own contract may run concurrently across
/// invocations — the actor gives every mutation a single, synchronized home
/// the way `OperationTool`'s own `RetryState` does for its retry counter.
internal actor NotesStore {
    /// Every note currently stored, keyed by id.
    private var notesByID: [String: Note] = [:]

    /// Every note id, in insertion order — `Dictionary` has no ordering
    /// guarantee, so `list()` needs a side channel to return notes in a
    /// stable, user-meaningful order.
    private var orderedIDs: [String] = []

    /// The id `insert(title:body:tags:)` assigns to its next note.
    private var nextSequence = 1

    /// Creates an empty store.
    internal init() {}

    /// Inserts a new note with a freshly assigned id.
    ///
    /// - Parameters:
    ///   - title: The note's title.
    ///   - body: The note's Markdown body, if any.
    ///   - tags: Tags to attach, in the given order.
    /// - Returns: The newly stored note, including its assigned id.
    internal func insert(title: String, body: String?, tags: [String]) -> Note {
        let note = Note(id: "note-\(nextSequence)", title: title, body: body, tags: tags)
        nextSequence += 1
        notesByID[note.id] = note
        orderedIDs.append(note.id)
        return note
    }

    /// Looks up a note by id.
    ///
    /// - Parameter id: The note id to look up.
    /// - Returns: The matching note, or `nil` if no note has that id.
    internal func find(id: String) -> Note? {
        notesByID[id]
    }

    /// Every stored note, in insertion order.
    internal func list() -> [Note] {
        orderedIDs.compactMap { notesByID[$0] }
    }

    /// Removes a note by id.
    ///
    /// - Parameter id: The note id to remove.
    /// - Returns: The removed note, or `nil` if no note had that id (in
    ///   which case the store is left unchanged).
    internal func remove(id: String) -> Note? {
        guard let note = notesByID.removeValue(forKey: id) else { return nil }
        orderedIDs.removeAll { $0 == id }
        return note
    }

    /// Appends `tags` to a note's existing tags, skipping any already
    /// present, and returns the updated note.
    ///
    /// - Parameters:
    ///   - tags: Tags to attach, in the given order.
    ///   - id: The id of the note to tag.
    /// - Returns: The updated note, or `nil` if no note had that id (in
    ///   which case the store is left unchanged).
    internal func addTags(_ tags: [String], toNoteWithID id: String) -> Note? {
        guard var note = notesByID[id] else { return nil }
        for tag in tags where !note.tags.contains(tag) {
            note.tags.append(tag)
        }
        notesByID[id] = note
        return note
    }
}
