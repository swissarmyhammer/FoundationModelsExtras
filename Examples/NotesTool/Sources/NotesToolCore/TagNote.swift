import FoundationModels
import Operations

/// Attaches tags to an existing note, skipping any it already has.
@Generable
@Operation(verb: "tag", noun: "note", description: "Attach tags to an existing note")
internal struct TagNote {
    @Guide(description: "The note id")
    @OperationParam(short: "i")
    var id: String

    @Guide(description: "Tags to attach")
    var tags: [String]
}

extension TagNote {
    func execute(in context: NotesContext) async throws -> Note {
        try requiringNote(await context.store.addTags(tags, toNoteWithID: id), id: id)
    }
}
