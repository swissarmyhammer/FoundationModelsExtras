import FoundationModels
import Operations

/// Deletes a note by id, returning the note as it was just before deletion.
@Generable
@Operation(verb: "delete", noun: "note", description: "Delete a note by id")
internal struct DeleteNote {
    @Guide(description: "The note id")
    @OperationParam(short: "i")
    var id: String
}

extension DeleteNote {
    func execute(in context: NotesContext) async throws -> Note {
        try requiringNote(await context.store.remove(id: id), id: id)
    }
}
