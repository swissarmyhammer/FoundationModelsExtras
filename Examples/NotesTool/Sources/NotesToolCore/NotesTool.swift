import FoundationModels
import Operations

/// The fused "notes" `OperationTool`'s public factory and shared naming —
/// plan.md's task 7 worked example of the full stack: `@Operation`-declared
/// operations (`AddNote`/`GetNote`/`ListNotes`/`DeleteNote`/`TagNote`) fused
/// by `OperationTool` and driven by both `OperationCLIDriver` (the `notes`
/// executable's default mode) and a `LanguageModelSession` (its `--chat`
/// mode).
public enum NotesTool {
    /// The fused tool's model- and CLI-facing name.
    public static let name = "notes"

    /// A human- and model-facing summary of the fused tool.
    public static let description = "Manage the user's notes: add, get, list, delete, and tag them."

    /// Builds the fused "notes" tool.
    ///
    /// Exposed as a factory rather than a stored/computed singleton because
    /// `OperationTool.init` throws, and because the `--chat` live-model
    /// harness needs two distinct instances differing only in
    /// `includesSchemaInInstructions` to measure plan.md's "Schema-in-prompt
    /// cost" delta.
    ///
    /// - Parameter includesSchemaInInstructions: Whether FoundationModels
    ///   injects the fused schema into the prompt. Defaults to `true`.
    /// - Returns: The fused tool, ready to drive both `OperationCLIDriver`
    ///   and a `LanguageModelSession`.
    /// - Throws: `SchemaFusionError.reservedParameterName` if the fused
    ///   schema collides with the `op` discriminator (not expected for this
    ///   fixed operation set, but propagated per `OperationTool.init`'s
    ///   contract); rethrows `GenerationSchema.SchemaError` on any other
    ///   schema-fusion failure.
    public static func make(includesSchemaInInstructions: Bool = true) throws -> OperationTool<NotesContext> {
        try OperationTool(
            name: name,
            description: description,
            context: NotesContext(),
            operations: [
                AnyOperation(AddNote.self),
                AnyOperation(GetNote.self),
                AnyOperation(ListNotes.self),
                AnyOperation(DeleteNote.self),
                AnyOperation(TagNote.self),
            ],
            includesSchemaInInstructions: includesSchemaInInstructions
        )
    }
}
