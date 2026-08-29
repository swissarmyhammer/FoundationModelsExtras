import FoundationModels
import Operations

/// Creates a new note, per plan.md's "Declaring an operation" example.
@Generable
@Operation(verb: "add", noun: "note", description: "Create a new note")
internal struct AddNote {
    @Guide(description: "The note title")
    @OperationParam(short: "t")
    var title: String

    @Guide(description: "Markdown body of the note")
    @OperationParam(short: "b")
    var body: String?

    @Guide(description: "Tags to attach")
    var tags: [String]?
}

extension AddNote {
    func execute(in context: NotesContext) async throws -> Note {
        await context.store.insert(title: title, body: body, tags: tags ?? [])
    }
}
