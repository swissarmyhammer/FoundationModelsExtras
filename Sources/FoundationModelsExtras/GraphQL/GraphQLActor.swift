import Foundation
import Graphiti

/// The person who makes one GraphQL call: the id, the name, and the earlier ids of the person.
///
/// The client sends the actor in the `_meta` of `initialize`, under ``initializeMetaKey``. The host accepts the claim
/// only from a ``GraphQLViewer/Trust/userDevice`` client, and fills it into ``GraphQLViewer/actor``. An endpoint
/// writes each change as the actor of the viewer, or as the agent of the session when there is no actor.
public struct GraphQLActor: Codable, Hashable, Sendable {
    /// The `_meta` key of `initialize` that holds the actor.
    public static let initializeMetaKey = "sah/actor"

    /// The id of the person, for example the iCloud user record id, or `local/<user name>`.
    public var id: String

    /// The name of the person, for example the full user name of the Mac.
    public var name: String

    /// The earlier ids of the same person, for example `local/<user name>` after the person signs in to iCloud.
    public var aliases: [String]

    /// Makes an actor.
    ///
    /// - Parameters:
    ///   - id: The id of the person.
    ///   - name: The name of the person.
    ///   - aliases: The earlier ids of the same person.
    public init(id: String, name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }

    /// Decodes an actor. A payload with no `aliases` key gives an empty list.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when `id` or `name` is missing or has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    /// Tells if an id is an id of this person.
    ///
    /// - Parameter id: The id to match, for example the actor of an old change.
    /// - Returns: `true` when the id is ``id`` or is in ``aliases``.
    public func matches(id: String) -> Bool {
        self.id == id || aliases.contains(id)
    }

    /// Gives the actor as a JSON value of the caller's JSON type, for the `_meta` of `initialize`.
    ///
    /// The caller puts the value under ``initializeMetaKey`` in the `_meta` object.
    ///
    /// - Parameter type: The JSON value type, for example the `JSONValue` of the ACP wire package.
    /// - Returns: The actor as a JSON object.
    /// - Throws: An error when the JSON value type cannot decode a JSON object.
    public func metaValue<Value: Decodable>(as type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    /// Reads the actor from the `_meta` object of `initialize`.
    ///
    /// This function does not throw, because a bad claim must not fail `initialize`. It does not decide trust: the
    /// host calls it only for a ``GraphQLViewer/Trust/userDevice`` client.
    ///
    /// - Parameter meta: The `_meta` object, in any JSON value type that encodes as JSON.
    /// - Returns: The actor, or `nil` when `meta` is `nil` or is not an object, when it has no ``initializeMetaKey``
    ///   member, when the member has a bad shape, or when the id or the name is empty after trimming.
    public static func fromMeta<Meta: Encodable>(_ meta: Meta?) -> GraphQLActor? {
        guard let meta,
            let data = try? JSONEncoder().encode(meta),
            let claim = try? JSONDecoder().decode(MetaClaim.self, from: data),
            let actor = claim.actor
        else { return nil }
        guard !actor.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !actor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return actor
    }

    /// The `_meta` object of `initialize`, with only the actor member.
    private struct MetaClaim: Decodable {
        /// The actor, or `nil` when the member is not there.
        let actor: GraphQLActor?

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue _: Int) {
                nil
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            actor = try container.decodeIfPresent(
                GraphQLActor.self,
                forKey: Key(stringValue: GraphQLActor.initializeMetaKey)
            )
        }
    }
}

extension SchemaBuilder {
    /// Adds the `Actor` type to the schema: `type Actor { id: String! name: String! aliases: [String!]! }`.
    ///
    /// Each endpoint calls this method and adds a field `actor` of this type on its own viewer type, so that every
    /// endpoint gives `viewer { actor { id name aliases } }` in the same form.
    ///
    /// - Returns: This builder, for method chaining.
    @discardableResult
    public func addActorType() -> Self {
        add {
            Type(GraphQLActor.self, as: "Actor") {
                Field("id", at: \.id).description("The id of the person.")
                Field("name", at: \.name).description("The name of the person.")
                Field("aliases", at: \.aliases).description("The earlier ids of the same person.")
            }
            .description("The person who makes the call.")
        }
    }
}
