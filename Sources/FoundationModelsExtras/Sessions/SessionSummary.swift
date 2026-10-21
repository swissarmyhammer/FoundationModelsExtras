import Foundation
import ULID

/// The facts of one session that the directory knows.
public struct SessionSummary: Sendable, Codable, Equatable, Identifiable {
    /// The session id. It is also the ACP session id.
    public let id: ULID

    /// The id of the agent in the agent catalog (D61). `default` for the
    /// root `Agents/AGENT.md`. For a folder agent that is not in the catalog
    /// (D71), `folder:` plus the absolute path of its folder.
    public var agentID: String

    /// The display name of the agent, from the `name` key of its `AGENT.md`.
    public var agentName: String?

    /// The working folder (the cwd). With no folder at the start, it is the
    /// folder of the session that started it (AG-5).
    public var workingDirectory: URL

    /// The title of the session, if a user or a session gave one.
    public var title: String?

    /// The tags of the session.
    public var tags: Set<String>

    /// The kind of the session.
    public var kind: SessionKind

    /// The work state of the session.
    public var state: SessionState

    /// Subagent: the parent session (agentSpawn). Fork: the original session.
    public var parentID: ULID?

    /// Root session that another session started (tool, message, trigger).
    /// It is not a parent: the session is not a subagent.
    public var startedBy: ULID?

    /// How the session started.
    public var origin: SessionDirectoryOrigin

    /// The time the session started.
    public var createdAt: Date

    /// The time of the last change of the facts or the state of the session.
    public var updatedAt: Date

    /// The last final message of the session, cut to a fixed length.
    public var lastSummary: String?

    /// True when the session is in memory now.
    public var isLive: Bool

    /// Makes a summary.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - agentID: The id of the agent in the agent catalog.
    ///   - agentName: The display name of the agent. The default is `nil`.
    ///   - workingDirectory: The working folder.
    ///   - title: The title of the session. The default is `nil`.
    ///   - tags: The tags of the session.
    ///   - kind: The kind of the session.
    ///   - state: The work state of the session.
    ///   - parentID: The parent or the original session. The default is `nil`.
    ///   - startedBy: The session that started this root session. The
    ///     default is `nil`.
    ///   - origin: How the session started.
    ///   - createdAt: The time the session started.
    ///   - updatedAt: The time of the last change.
    ///   - lastSummary: The last final message, cut to a fixed length. The
    ///     default is `nil`.
    ///   - isLive: True when the session is in memory now.
    public init(
        id: ULID,
        agentID: String,
        agentName: String? = nil,
        workingDirectory: URL,
        title: String? = nil,
        tags: Set<String>,
        kind: SessionKind,
        state: SessionState,
        parentID: ULID? = nil,
        startedBy: ULID? = nil,
        origin: SessionDirectoryOrigin,
        createdAt: Date,
        updatedAt: Date,
        lastSummary: String? = nil,
        isLive: Bool
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.workingDirectory = workingDirectory
        self.title = title
        self.tags = tags
        self.kind = kind
        self.state = state
        self.parentID = parentID
        self.startedBy = startedBy
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSummary = lastSummary
        self.isLive = isLive
    }
}
