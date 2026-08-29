/// Shared key vocabulary and normalization for the fused schema's `op`
/// discriminator and the forgiving resolver.
///
/// `SchemaFusion` (reserved-parameter-name check, at fusion time) and
/// `OperationResolver` (parameter key aliasing, at dispatch time) both need
/// to treat names that differ only by case or `_`/`-` separators as the same
/// key. This is the single place that defines what "the same, ignoring case
/// and separators" means, so the two call sites can't drift apart.
public enum OperationKeys {
    /// The fused schema's discriminator property name.
    ///
    /// Public so `OperationsCLI`'s macro-less fallback leaf — which, unlike
    /// the macro-generated `Command`, has no compiler-plugin-side copy of
    /// this literal to fall back on — can build the identical canonical
    /// payload shape `AnyOperation.run` expects without duplicating it.
    public static let opFieldName = "op"

    /// The fused schema's discriminator property description.
    internal static let opFieldDescription = "The operation to perform, as \"verb noun\"."

    /// Normalizes `name` for case/separator-insensitive comparison:
    /// lowercased with `_`/`-` separators removed, so `"Op"`, `"_op"`,
    /// `"o-p"`, and `"noteTitle"`/`"note_title"`/`"note-title"` all compare
    /// equal.
    internal static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" }
    }
}
