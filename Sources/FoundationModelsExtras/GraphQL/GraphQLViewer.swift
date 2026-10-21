/// The client that makes one GraphQL call: the client id, the trust of the client, and the sessions that it owns.
///
/// The host fills a viewer for each call that a client sends through the GraphQL tunnel. A resolver reads it for its
/// visibility and owner rules: for example, an ``Trust/external`` client acts only on the sessions that it owns. A
/// model tool call has no client, so it gives no viewer to ``GraphQLEndpoint``.
public struct GraphQLViewer: Codable, Hashable, Sendable {
    /// The trust of a client.
    public enum Trust: String, Codable, CaseIterable, Hashable, Sendable {
        /// A device of the user, for example the Mac app or the iPad of the user.
        case userDevice

        /// A client that is not a device of the user.
        case external
    }

    /// The id of the client.
    public var clientId: String

    /// The trust of the client.
    public var trust: Trust

    /// The ids of the sessions that this client owns.
    public var ownedSessions: Set<String>

    /// The ids of the sessions that a client owns, this client or a different one. A session that is not in this set
    /// has no client owner, for example a session that the agent started.
    public var clientOwnedSessions: Set<String>

    /// The ids of the sessions that the connection of this client started. A session stays in this set when a
    /// different client takes it over, for example a device of the user, so it can leave ``ownedSessions`` and
    /// stay here.
    public var startedSessions: Set<String>

    /// Makes the viewer of a call.
    ///
    /// - Parameters:
    ///   - clientId: The id of the client.
    ///   - trust: The trust of the client.
    ///   - ownedSessions: The ids of the sessions that this client owns.
    ///   - clientOwnedSessions: The ids of the sessions that any client owns. The set holds each id of
    ///     `ownedSessions` also when the caller does not give it.
    ///   - startedSessions: The ids of the sessions that the connection of this client started.
    public init(
        clientId: String,
        trust: Trust,
        ownedSessions: Set<String> = [],
        clientOwnedSessions: Set<String> = [],
        startedSessions: Set<String> = []
    ) {
        self.clientId = clientId
        self.trust = trust
        self.ownedSessions = ownedSessions
        self.clientOwnedSessions = clientOwnedSessions.union(ownedSessions)
        self.startedSessions = startedSessions
    }

    /// Decodes a viewer. A payload with no `startedSessions` key, from before the field, gives an empty set.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when a field that the viewer needs is missing or has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .clientId)
        trust = try container.decode(Trust.self, forKey: .trust)
        ownedSessions = try container.decode(Set<String>.self, forKey: .ownedSessions)
        clientOwnedSessions = try container.decode(Set<String>.self, forKey: .clientOwnedSessions)
        startedSessions = try container.decodeIfPresent(Set<String>.self, forKey: .startedSessions) ?? []
    }

    /// Tells if this client owns a session.
    ///
    /// - Parameter sessionId: The id of the session.
    /// - Returns: `true` when the session is in ``ownedSessions``.
    public func owns(_ sessionId: String) -> Bool {
        ownedSessions.contains(sessionId)
    }
}
