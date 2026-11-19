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

    /// The time that a client pinned the session, or `nil` when it is not
    /// pinned. The Pinned list shows the pinned sessions in the order of
    /// this time, the first pin first. A second pin keeps the first time.
    public var pinnedAt: Date?

    /// The time that a client used the session last, or `nil` when no
    /// client used it. The Recent list shows the sessions in the order of
    /// this time, the newest first.
    public var lastUsedAt: Date?

    /// The time that the session was archived, or `nil` when it is not
    /// archived. An archive sets it, and an unarchive clears it. The
    /// Archived list shows the sessions in the order of this time, the
    /// newest first.
    public var archivedAt: Date?

    /// One sentence of at most 200 characters that tells what the session
    /// did and where it stands now, or `nil` when the session has none. A
    /// model makes it after a turn. It does not change the name of the
    /// session. A new recap goes out as `factsChanged`.
    public var recap: String?

    /// The time that the directory made ``recap``, or `nil` when the
    /// session has no recap.
    public var recapAt: Date?

    /// Where an imported session came from, or `nil` when the session was
    /// not imported. An imported session has the origin
    /// ``SessionDirectoryOrigin/import``.
    public var importedFrom: SessionImportProvenance?

    /// True when the session is pinned, that is, it has a ``pinnedAt``.
    public var isPinned: Bool { pinnedAt != nil }

    /// The number of characters of ``shortID``.
    private static let shortIDLength = 7

    /// The short id of the session: the last 7 characters of the text of
    /// ``id``, in lower case. A person can type it to find the session.
    public var shortID: String {
        String(id.ulidString.suffix(Self.shortIDLength)).lowercased()
    }

    /// The slug of the session: the slug of ``title`` that
    /// ``SessionSlug/make(from:)`` makes. When that slug is empty, for
    /// example when the session has no title, the slug is ``shortID``.
    public var slug: String {
        let titleSlug = SessionSlug.make(from: title ?? "")
        return titleSlug.isEmpty ? shortID : titleSlug
    }

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
    ///   - pinnedAt: The time of the pin. The default is `nil`: the session
    ///     is not pinned.
    ///   - lastUsedAt: The time of the last use. The default is `nil`: no
    ///     client used the session.
    ///   - archivedAt: The time of the archive. The default is `nil`: the
    ///     session is not archived.
    ///   - recap: The recap of the session. The default is `nil`: the
    ///     session has no recap.
    ///   - recapAt: The time of the recap. The default is `nil`.
    ///   - importedFrom: Where an imported session came from. The default is
    ///     `nil`: the session was not imported.
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
        isLive: Bool,
        pinnedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        archivedAt: Date? = nil,
        recap: String? = nil,
        recapAt: Date? = nil,
        importedFrom: SessionImportProvenance? = nil
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
        self.pinnedAt = pinnedAt
        self.lastUsedAt = lastUsedAt
        self.archivedAt = archivedAt
        self.recap = recap
        self.recapAt = recapAt
        self.importedFrom = importedFrom
    }
}
