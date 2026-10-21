import Foundation
import ULID

/// A request to start a new root session: an agent plus a working folder.
public struct SessionStartRequest: Sendable, Codable, Equatable {
    /// Nil: the `AGENT.md` of the working folder, else the default agent
    /// (D71). The launcher resolves it.
    public var agentID: String?

    /// Nil: the folder of `startedBy` (AG-5). The launcher resolves it.
    public var workingDirectory: URL?

    /// The message that starts the first turn of the session.
    public var firstMessage: String

    /// The tags that the session starts with.
    public var tags: Set<String>

    /// The title that the session starts with.
    public var title: String?

    /// The session that asked for the start, or `nil` for a start by a UI
    /// or a trigger.
    public var startedBy: ULID?

    /// The UI client that asked for the start, for the tab rule. Nil for a
    /// start by a session or a trigger.
    public var requestedByClient: String?

    /// How the session starts.
    public var origin: SessionDirectoryOrigin

    /// Makes a start request.
    ///
    /// - Parameters:
    ///   - agentID: The id of the agent. The default is `nil`: the launcher
    ///     resolves it.
    ///   - workingDirectory: The working folder. The default is `nil`: the
    ///     launcher resolves it.
    ///   - firstMessage: The message that starts the first turn.
    ///   - tags: The tags that the session starts with. The default is none.
    ///   - title: The title that the session starts with. The default is
    ///     `nil`.
    ///   - startedBy: The session that asks for the start. The default is
    ///     `nil`.
    ///   - requestedByClient: The UI client that asks for the start. The
    ///     default is `nil`.
    ///   - origin: How the session starts.
    public init(
        agentID: String? = nil,
        workingDirectory: URL? = nil,
        firstMessage: String,
        tags: Set<String> = [],
        title: String? = nil,
        startedBy: ULID? = nil,
        requestedByClient: String? = nil,
        origin: SessionDirectoryOrigin
    ) {
        self.agentID = agentID
        self.workingDirectory = workingDirectory
        self.firstMessage = firstMessage
        self.tags = tags
        self.title = title
        self.startedBy = startedBy
        self.requestedByClient = requestedByClient
        self.origin = origin
    }
}
