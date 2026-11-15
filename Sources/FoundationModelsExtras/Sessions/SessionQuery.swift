import Foundation
import ULID

/// A filter for ``SessionDirectory/sessions(matching:)``. Each field that is
/// not nil must match.
public struct SessionQuery: Sendable, Codable, Equatable {
    /// The number of summaries that a query gives when the caller names no
    /// limit. It is the default of the `list sessions` operation of the
    /// `sessions` tool.
    public static let defaultLimit = 20

    /// The working folder of the sessions.
    public var workingDirectory: URL?

    /// The id of the agent of the sessions.
    public var agentID: String?

    /// A tag that each session has.
    public var tag: String?

    /// The kind of the sessions.
    public var kind: SessionKind?

    /// The work state of the sessions.
    public var state: SessionState?

    /// The parent or the original session of the sessions.
    public var parentID: ULID?

    /// The session that started the sessions.
    public var startedBy: ULID?

    /// True: only the pinned sessions. False: only the sessions that are
    /// not pinned.
    public var pinned: Bool?

    /// False: only the live sessions. True: also the sessions that are on
    /// disk only, the archived ones too.
    public var includesRecorded: Bool

    /// The order of the summaries. The directory applies it before
    /// ``limit``.
    public var order: SessionOrder

    /// The maximum number of summaries that the query gives.
    public var limit: Int

    /// Makes a query.
    ///
    /// - Parameters:
    ///   - workingDirectory: The working folder. The default is `nil`.
    ///   - agentID: The id of the agent. The default is `nil`.
    ///   - tag: A tag that each session has. The default is `nil`.
    ///   - kind: The kind of the sessions. The default is `nil`.
    ///   - state: The work state of the sessions. The default is `nil`.
    ///   - parentID: The parent or the original session. The default is `nil`.
    ///   - startedBy: The session that started the sessions. The default is
    ///     `nil`.
    ///   - pinned: True for only the pinned sessions, false for only the
    ///     sessions that are not pinned. The default is `nil`.
    ///   - includesRecorded: True to also find the sessions that are on disk
    ///     only. The default is `false`.
    ///   - order: The order of the summaries. The default is
    ///     ``SessionOrder/newestFirst``.
    ///   - limit: The maximum number of summaries. The default is
    ///     ``defaultLimit``.
    public init(
        workingDirectory: URL? = nil,
        agentID: String? = nil,
        tag: String? = nil,
        kind: SessionKind? = nil,
        state: SessionState? = nil,
        parentID: ULID? = nil,
        startedBy: ULID? = nil,
        pinned: Bool? = nil,
        includesRecorded: Bool = false,
        order: SessionOrder = .newestFirst,
        limit: Int = Self.defaultLimit
    ) {
        self.workingDirectory = workingDirectory
        self.agentID = agentID
        self.tag = tag
        self.kind = kind
        self.state = state
        self.parentID = parentID
        self.startedBy = startedBy
        self.pinned = pinned
        self.includesRecorded = includesRecorded
        self.order = order
        self.limit = limit
    }
}
