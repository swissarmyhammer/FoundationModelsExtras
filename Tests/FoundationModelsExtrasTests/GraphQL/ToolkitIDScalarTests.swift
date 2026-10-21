import Foundation
import Graphiti
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// The context of one call of the id echo example.
struct IDEchoContext: Sendable {}

/// The arguments of `Query.echo` of the id echo example.
struct IDEchoArguments: Codable, Sendable {
    /// The id to give back.
    let id: ToolkitID
}

/// The root resolver of the id echo example.
struct IDEchoResolver: Sendable {
    /// Resolves `Query.echo`: gives the id back.
    func echo(context _: IDEchoContext, arguments: IDEchoArguments) -> ToolkitID {
        arguments.id
    }
}

/// A small Graphiti engine with one field `echo(id: ID!): ID!` over the toolkit `ID` scalar.
struct IDEchoAPI: API {
    let resolver = IDEchoResolver()
    let schema: Schema<IDEchoResolver, IDEchoContext>

    /// Builds the schema.
    init() throws {
        schema = try SchemaBuilder(IDEchoResolver.self, IDEchoContext.self)
            .addToolkitIDScalar()
            .addQuery {
                Field("echo", at: IDEchoResolver.echo) {
                    Argument("id", at: \.id).description("The id to give back.")
                }
                .description("Gives the id back.")
            }
            .build()
    }
}

/// A package id with its own scalar named `ID`, the way Kanban and Skills register one.
struct PackageOwnID: Codable, Sendable {
    /// The text of the id.
    let text: String
}

/// The root resolver of a schema with its own scalar named `ID`.
struct PackageOwnIDResolver: Sendable {
    /// Resolves `Query.first`.
    func first(context _: IDEchoContext, arguments _: NoArguments) -> PackageOwnID {
        PackageOwnID(text: "first")
    }
}

/// Proves the toolkit `ID` scalar: the input forms it takes, its output, the SDL of an ``IDChange``, and that
/// `addToolkitScalars()` leaves the name `ID` free for a package that has its own scalar.
@Suite("Toolkit ID scalar")
struct ToolkitIDScalarTests {
    @Test("the ID scalar takes a String or an Int literal, and gives a String")
    func idScalarTakesStringAndIntLiterals() async throws {
        let result = try await IDEchoAPI().execute(
            request: #"{ text: echo(id: "n1") number: echo(id: 7) }"#,
            context: IDEchoContext()
        )

        #expect(result == GraphQLResult(data: ["text": "n1", "number": "7"]))
    }

    @Test("the ID scalar takes a String or an Int variable, and gives a String")
    func idScalarTakesStringAndIntVariables() async throws {
        let api = try IDEchoAPI()
        let document = "query Echo($id: ID!) { echo(id: $id) }"

        let text = try await api.execute(request: document, context: IDEchoContext(), variables: ["id": "n1"])
        let number = try await api.execute(request: document, context: IDEchoContext(), variables: ["id": 7])

        #expect(text == GraphQLResult(data: ["echo": "n1"]))
        #expect(number == GraphQLResult(data: ["echo": "7"]))
    }

    @Test("the ID scalar refuses a Float literal")
    func idScalarRefusesAFloat() async throws {
        let result = try await IDEchoAPI().execute(request: "{ echo(id: 1.5) }", context: IDEchoContext())

        #expect(result.data == nil)
        #expect(result.errors.count == 1)
    }

    @Test("the SDL of a change built from IDChange has added, changed and removed as [ID!]!")
    func idChangeMapsToIDLists() throws {
        let sdl = try ExampleGraph().schema

        #expect(sdl.contains("added: [ID!]!"))
        #expect(sdl.contains("changed: [ID!]!"))
        #expect(sdl.contains("removed: [ID!]!"))
    }

    @Test("addToolkitScalars adds no ID, so a schema with its own scalar named ID still builds")
    func toolkitScalarsLeaveTheIDNameFree() throws {
        let schema = try SchemaBuilder(PackageOwnIDResolver.self, IDEchoContext.self)
            .addToolkitScalars()
            .add {
                Scalar(PackageOwnID.self, as: "ID").description("The id of the package.")
            }
            .addQuery {
                Field("first", at: PackageOwnIDResolver.first).description("The first id.")
            }
            .build()

        #expect(printSchema(schema: schema.schema).contains("first: ID!"))
    }
}
