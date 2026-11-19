import Foundation
import FoundationModels
import ULID

// MARK: - Imports

extension InMemorySessionDirectoryState {
    /// Imports a session: adds an idle root session that is recorded and not
    /// live, with the origin `import` and the provenance of the request, and
    /// keeps its history. A session that is not live sends no `started`,
    /// thus the import sends one `factsChanged` with the new summary, so a
    /// host learns of the session.
    ///
    /// The name is the title of the request when no session in the folder
    /// that is not archived has its slug. Else it is the slug of the title
    /// with the next free number, from ``SessionName/default(agentName:usedNames:)``.
    ///
    /// - Parameters:
    ///   - request: The import request.
    ///   - transcript: The history of the imported session.
    ///   - now: The time of the import.
    /// - Returns: The summary of the imported session.
    /// - Throws: ``SessionDirectoryError/noLauncher`` and the errors of the
    ///   launcher for the agent.
    mutating func importSession(
        _ request: SessionImportRequest,
        transcript: Transcript,
        at now: Date
    ) throws -> SessionSummary {
        guard let launcher else { throw SessionDirectoryError.noLauncher }
        let agentID = try launcher.resolveAgent(request.agentID)
        let folder = request.workingDirectory
        let summary = SessionSummary(
            id: ULID(),
            agentID: agentID,
            workingDirectory: folder,
            title: Self.importName(of: request.title, usedNames: usedNames(in: folder)),
            tags: [],
            kind: .root,
            state: .idle,
            startedBy: request.startedBy,
            origin: .import,
            createdAt: now,
            updatedAt: now,
            isLive: false,
            importedFrom: request.provenance)
        importedTranscripts[summary.id] = transcript
        insert(summary, requestedByClient: nil)
        emit(.factsChanged(summary))
        return summary
    }

    /// The name of an imported session: the title, or the slug of the title
    /// with the next free number when a used name has its slug.
    ///
    /// - Parameters:
    ///   - title: The title of the request.
    ///   - usedNames: The slugs of the sessions in the folder that are not
    ///     archived.
    /// - Returns: The name.
    private static func importName(of title: String, usedNames: Set<String>) -> String {
        let slug = SessionSlug.make(from: title)
        guard !slug.isEmpty, usedNames.contains(slug) else { return title }
        return SessionName.default(agentName: title, usedNames: usedNames)
    }
}
