import Foundation
import Graphiti
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// A JSON value type for the tests, like the `JSONValue` of the ACP wire package.
private enum TestJSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([TestJSON])
    case object([String: TestJSON])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TestJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TestJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// The context of one call of the actor example.
private struct ActorContext: GraphQLRunContext {
    let warnings = ResponseWarnings()
}

/// The root resolver of the actor example.
private struct ActorResolver: Sendable {
    let actor: GraphQLActor

    /// Resolves `Query.actor`.
    func actor(context _: ActorContext, arguments _: NoArguments) -> GraphQLActor {
        actor
    }
}

/// A small Graphiti engine that gives one actor through the `Actor` type of the toolkit.
private struct ActorAPI: API {
    let resolver: ActorResolver
    let schema: Schema<ActorResolver, ActorContext>

    init(actor: GraphQLActor) throws {
        resolver = ActorResolver(actor: actor)
        schema = try SchemaBuilder(ActorResolver.self, ActorContext.self)
            .addActorType()
            .addQuery {
                Field("actor", at: ActorResolver.actor).description("The actor.")
            }
            .build()
    }
}

@Suite("GraphQLActor")
struct GraphQLActorTests {
    private let person = GraphQLActor(id: "icloud/_abc", name: "Will Ballard", aliases: ["local/wballard"])

    @Test("an actor survives an encode and decode")
    func actorRoundTrip() throws {
        let decoded = try JSONDecoder().decode(GraphQLActor.self, from: try JSONEncoder().encode(person))

        #expect(decoded == person)
    }

    @Test("an actor with no aliases key decodes with no aliases")
    func actorWithNoAliasesDecodes() throws {
        let json = #"{"id":"local/wballard","name":"Will Ballard"}"#

        let actor = try JSONDecoder().decode(GraphQLActor.self, from: Data(json.utf8))

        #expect(actor == GraphQLActor(id: "local/wballard", name: "Will Ballard"))
    }

    @Test("an actor matches its id and its aliases, and no other id")
    func actorMatchesItsIds() {
        #expect(person.matches(id: "icloud/_abc"))
        #expect(person.matches(id: "local/wballard"))
        #expect(!person.matches(id: "external/ipad"))
    }

    @Test("the actor of a viewer survives an encode and decode")
    func viewerActorRoundTrip() throws {
        let viewer = GraphQLViewer(clientId: "mac", trust: .userDevice, ownedSessions: ["s1"], actor: person)

        let decoded = try JSONDecoder().decode(GraphQLViewer.self, from: try JSONEncoder().encode(viewer))

        #expect(decoded == viewer)
        #expect(decoded.actor == person)
    }

    @Test("a viewer has no actor when the caller gives none")
    func viewerActorDefaultsToNil() {
        #expect(GraphQLViewer(clientId: "ipad", trust: .external).actor == nil)
    }

    @Test("a viewer encoded before the actor decodes with no actor")
    func viewerWithNoActorKeyDecodes() throws {
        let json =
            #"{"clientId":"ipad","trust":"external","ownedSessions":["s1"],"clientOwnedSessions":["s1"],"startedSessions":[]}"#

        let viewer = try JSONDecoder().decode(GraphQLViewer.self, from: Data(json.utf8))

        #expect(viewer.actor == nil)
        #expect(viewer == GraphQLViewer(clientId: "ipad", trust: .external, ownedSessions: ["s1"]))
    }

    @Test("a viewer with no actor encodes no actor key")
    func viewerWithNoActorEncodesNoKey() throws {
        let data = try JSONEncoder().encode(GraphQLViewer(clientId: "ipad", trust: .external))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["actor"] == nil)
    }

    @Test("the meta key is sah/actor")
    func metaKey() {
        #expect(GraphQLActor.initializeMetaKey == "sah/actor")
    }

    @Test("an actor survives the meta value and the read from meta")
    func metaRoundTrip() throws {
        let value = try person.metaValue(as: TestJSON.self)
        let meta = TestJSON.object([GraphQLActor.initializeMetaKey: value, "other": .bool(true)])

        #expect(
            value
                == .object([
                    "id": .string("icloud/_abc"),
                    "name": .string("Will Ballard"),
                    "aliases": .array([.string("local/wballard")]),
                ])
        )
        #expect(GraphQLActor.fromMeta(meta) == person)
    }

    @Test(
        "a read from meta gives no actor for a bad claim",
        arguments: [
            TestJSON.string("not an object"),
            .object([:]),
            .object(["other": .string("x")]),
            .object([GraphQLActor.initializeMetaKey: .string("x")]),
            .object([GraphQLActor.initializeMetaKey: .object(["name": .string("Will")])]),
            .object([GraphQLActor.initializeMetaKey: .object(["id": .string(" "), "name": .string("Will")])]),
            .object([GraphQLActor.initializeMetaKey: .object(["id": .string("local/w"), "name": .string(" \n")])]),
        ]
    )
    fileprivate func fromMetaRejectsBadClaim(meta: TestJSON) {
        #expect(GraphQLActor.fromMeta(meta) == nil)
    }

    @Test("a read from meta gives no actor for no meta")
    func fromMetaWithNoMeta() {
        #expect(GraphQLActor.fromMeta(TestJSON?.none) == nil)
    }

    @Test("the Actor type of the toolkit gives the id, the name and the aliases")
    func actorTypeAnswersAQuery() async throws {
        let api = try ActorAPI(actor: person)

        let response = try await api.respond(
            to: "{ actor { id name aliases } }",
            formattedWith: .sortedKeys,
            context: ActorContext()
        )

        #expect(response == #"{"data":{"actor":{"aliases":["local/wballard"],"id":"icloud/_abc","name":"Will Ballard"}}}"#)
    }
}
