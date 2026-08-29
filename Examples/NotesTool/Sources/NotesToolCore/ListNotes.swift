import FoundationModels
import Operations

/// Lists every stored note, in insertion order.
///
/// A unit struct: `@Operation` synthesizes an empty `parameterMetadata` and
/// a `Command` with no `@Option`/`@Flag` fields, only the `op` discriminator
/// — see `OperationMacroTests`'s "Unit struct (no fields)" fixture.
@Generable
@Operation(verb: "list", noun: "note", description: "List every note")
internal struct ListNotes {
}

extension ListNotes {
    func execute(in context: NotesContext) async throws -> [Note] {
        await context.store.list()
    }
}
