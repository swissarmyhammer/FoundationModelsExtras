/// The shared environment every notes operation's `execute(in:)` runs
/// against: an in-memory `NotesStore`.
///
/// Public only because it is `OperationTool`'s generic `Context` parameter —
/// part of `NotesTool.make(includesSchemaInInstructions:)`'s public return
/// type, `OperationTool<NotesContext>` — Swift requires a public function's
/// signature to name only types at least as visible as the function itself.
/// Its own members stay `internal`: nothing outside this module ever
/// constructs or inspects a `NotesContext` directly.
public struct NotesContext: Sendable {
    /// The note store this context's operations run against.
    internal let store: NotesStore

    /// Creates a context backed by `store`.
    ///
    /// - Parameter store: The note store to run operations against.
    ///   Defaults to a fresh, empty `NotesStore()`.
    internal init(store: NotesStore = NotesStore()) {
        self.store = store
    }
}
