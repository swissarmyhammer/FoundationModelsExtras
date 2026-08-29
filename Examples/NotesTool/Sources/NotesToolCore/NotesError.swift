/// An error raised by a notes operation's own `execute(in:)`, as opposed to
/// a resolver/dispatch failure `OperationTool` already handles (see
/// `OperationError`).
///
/// Thrown from `execute(in:)`, `NotesError` surfaces to `OperationTool.call`'s
/// caller as `OperationError.executionFailed` — per plan.md's "Error
/// handling — return, don't throw", only resolver-level failures (unknown
/// op, missing required parameters) are returned as corrective tool output;
/// an operation's own domain error is a fatal condition the host app must
/// handle.
internal enum NotesError: Error, Sendable, Equatable {
    /// No note exists with the given id.
    case notFound(id: String)
}

extension NotesError: CustomStringConvertible {
    /// A human-readable summary suitable for CLI and log output.
    internal var description: String {
        switch self {
        case .notFound(let id):
            return "No note found with id '\(id)'."
        }
    }
}

/// Returns `note`, or throws `NotesError.notFound(id:)` if it is `nil`.
///
/// The shared "look a note up by id, or fail" shape behind `GetNote`,
/// `DeleteNote`, and `TagNote`'s `execute(in:)`, which otherwise differ only
/// in which `NotesStore` method produced `note`.
///
/// - Parameters:
///   - note: The `NotesStore` lookup's result.
///   - id: The note id that was looked up, used to build the thrown error.
/// - Returns: `note`, unwrapped.
/// - Throws: `NotesError.notFound(id:)` if `note` is `nil`.
internal func requiringNote(_ note: Note?, id: String) throws -> Note {
    guard let note else {
        throw NotesError.notFound(id: id)
    }
    return note
}
