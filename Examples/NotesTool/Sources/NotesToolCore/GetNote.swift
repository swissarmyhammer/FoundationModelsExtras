import FoundationModels
import Operations

/// Fetches a single note by id.
@Generable
@Operation(verb: "get", noun: "note", description: "Fetch a single note by id")
internal struct GetNote {
    @Guide(description: "The note id")
    @OperationParam(short: "i")
    var id: String
}

extension GetNote {
    func execute(in context: NotesContext) async throws -> Note {
        try requiringNote(await context.store.find(id: id), id: id)
    }
}
