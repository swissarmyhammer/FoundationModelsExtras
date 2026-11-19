import Foundation
import ULID

/// A request to import a session that another agent recorded. The import
/// makes a recorded root session with the origin
/// ``SessionDirectoryOrigin/import``.
public struct SessionImportRequest: Sendable, Codable, Equatable {
    /// Nil: the `AGENT.md` of the working folder, else the default agent.
    public var agentID: String?

    /// The working folder of the imported session.
    public var workingDirectory: URL

    /// The title of the imported session. The directory adds the next free
    /// number when a session in the folder already has its name.
    public var title: String

    /// Where the session came from.
    public var provenance: SessionImportProvenance

    /// The session that asked for the import, or `nil` for an import by a
    /// UI.
    public var startedBy: ULID?

    /// Makes an import request.
    ///
    /// - Parameters:
    ///   - agentID: The id of the agent. The default is `nil`: the agent of
    ///     the folder.
    ///   - workingDirectory: The working folder.
    ///   - title: The title of the imported session.
    ///   - provenance: Where the session came from.
    ///   - startedBy: The session that asks for the import. The default is
    ///     `nil`.
    public init(
        agentID: String? = nil,
        workingDirectory: URL,
        title: String,
        provenance: SessionImportProvenance,
        startedBy: ULID? = nil
    ) {
        self.agentID = agentID
        self.workingDirectory = workingDirectory
        self.title = title
        self.provenance = provenance
        self.startedBy = startedBy
    }
}
