import Foundation

/// Conformers contribute slash commands to whatever session context they are
/// registered in (plan.md §2).
///
/// Deliberately independent of `FoundationModels.Tool`: a conformer may be a
/// tool, a companion object, or a pure discovery engine that ships no tool at
/// all (e.g. a package that resolves `commands/*.md` files through a
/// `DotfolderStack` and ships nothing else).
public protocol SlashCommandProviding: Sendable {
    /// Returns the commands this conformer currently contributes, resolved
    /// against `workingDirectory`.
    ///
    /// - Parameter workingDirectory: The session's current working
    ///   directory, e.g. for a conformer that resolves commands from files
    ///   under the project's dotfolder.
    /// - Returns: The conformer's current command set.
    func commands(workingDirectory: URL) async -> [SlashCommand]

    /// Pushed re-publications of this conformer's full command set when it
    /// changes mid-session (e.g. files added or removed under a watched
    /// dotfolder layer). Each element replaces the previously published set
    /// wholesale — there is no incremental diffing.
    ///
    /// `nil` for a static conformer whose command set never changes after
    /// construction.
    var commandUpdates: AsyncStream<[SlashCommand]>? { get }
}
