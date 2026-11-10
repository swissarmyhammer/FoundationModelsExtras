import Foundation
import Graphiti
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// The context of one call of the board example.
struct BoardContext: GraphQLRunContext {
    let warnings = ResponseWarnings()
}

/// The `input` object of `Mutation.moveTask` of the board example.
struct BoardMoveInput: Codable, Sendable {
    let id: ToolkitID
    let column: ToolkitID?
}

/// The arguments of `Mutation.moveTask`.
struct BoardMoveArguments: Codable, Sendable {
    let input: BoardMoveInput
}

/// The arguments of `Mutation.tagTasks`.
struct BoardTagArguments: Codable, Sendable {
    let ids: [ToolkitID]
    let tag: String
}

/// The root resolver of the board example.
struct BoardResolver: Sendable {
    /// Resolves `Mutation.moveTask`: gives `id→column`.
    func moveTask(context _: BoardContext, arguments: BoardMoveArguments) -> String {
        "\(arguments.input.id.text)→\(arguments.input.column?.text ?? "")"
    }

    /// Resolves `Mutation.tagTasks`: gives `tag:id,id`.
    func tagTasks(context _: BoardContext, arguments: BoardTagArguments) -> String {
        "\(arguments.tag):" + arguments.ids.map(\.text).joined(separator: ",")
    }
}

/// A small engine with `ID` positions: `moveTask(input: {id: ID!, column: ID})` and
/// `tagTasks(ids: [ID!]!, tag: String!)`.
struct BoardAPI: API {
    let resolver = BoardResolver()
    let schema: Schema<BoardResolver, BoardContext>

    /// Builds the schema.
    init() throws {
        schema = try SchemaBuilder(BoardResolver.self, BoardContext.self)
            .addToolkitIDScalar()
            .add {
                Input(BoardMoveInput.self, as: "MoveTaskInput") {
                    InputField("id", at: \.id).description("The task.")
                    InputField("column", at: \.column).description("The column.")
                }
                .description("A move of a task.")
            }
            .addQuery {
                Field("ping", at: { (_: BoardResolver) in { (_: BoardContext, _: NoArguments) in "pong" } })
                    .description("Gives pong.")
            }
            .addMutation {
                Field("moveTask", at: BoardResolver.moveTask) {
                    Argument("input", at: \.input).description("The move.")
                }
                .description("Moves a task.")
                Field("tagTasks", at: BoardResolver.tagTasks) {
                    Argument("ids", at: \.ids).description("The tasks.")
                    Argument("tag", at: \.tag).description("The tag.")
                }
                .description("Tags tasks.")
            }
            .build()
    }
}

/// Proves that a variable declared `String` reads as `ID` where every read of it is an `ID` position, and `ID` as
/// `String` where every read is a `String` position, with a warning.
@Suite("Variable type coercion between String and ID")
struct VariableTypeCoercionTests {
    /// Runs one document against the board example.
    static func run(_ query: String, variables: [String: Map]) async throws -> String {
        try await BoardAPI().respond(to: query, variables: variables, context: BoardContext())
    }

    @Test("a String! variable at an ID position reads as ID, and the response gives its warning")
    func stringVariableAtAnIDPosition() async throws {
        let response = try await Self.run(
            #"mutation($col: String!) { moveTask(input: { id: "585j6dd", column: $col }) }"#,
            variables: ["col": "Done"]
        )

        #expect(try ResponseJSON.codes(response).isEmpty)
        #expect(response.contains(#""moveTask":"585j6dd→Done""#))
        #expect(try ResponseJSON.warningCodes(response) == [DocumentRewriter.coercedVariableTypeWarningCode])
        #expect(response.contains("$col"))
    }

    @Test("a [String!]! variable at an [ID!]! position reads as [ID!]!")
    func stringListAtAnIDListPosition() async throws {
        let response = try await Self.run(
            #"mutation($ids: [String!]!) { tagTasks(ids: $ids, tag: "bug") }"#,
            variables: ["ids": ["a", "b"]]
        )

        #expect(try ResponseJSON.codes(response).isEmpty)
        #expect(response.contains(#""tagTasks":"bug:a,b""#))
        #expect(try ResponseJSON.warningCodes(response) == [DocumentRewriter.coercedVariableTypeWarningCode])
    }

    @Test("an ID! variable at a String position reads as String")
    func idVariableAtAStringPosition() async throws {
        let response = try await Self.run(
            #"mutation($tag: ID!) { tagTasks(ids: ["a"], tag: $tag) }"#,
            variables: ["tag": "bug"]
        )

        #expect(try ResponseJSON.codes(response).isEmpty)
        #expect(response.contains(#""tagTasks":"bug:a""#))
        #expect(try ResponseJSON.warningCodes(response) == [DocumentRewriter.coercedVariableTypeWarningCode])
    }

    @Test("each of two operations that declare one variable name gets its own coercion")
    func twoOperationsEachCoerce() async throws {
        let schema = try BoardAPI().schema.schema
        let document = """
            mutation A($x: String!) { moveTask(input: { id: $x }) }
            mutation B($x: String!) { moveTask(input: { id: "t", column: $x }) }
            """

        let rewritten = try DocumentRewriter(for: schema).rewrittenDocument(from: document)

        #expect(rewritten.text.components(separatedBy: "$x: ID!").count == 3)
        #expect(rewritten.warnings.map(\.code) == Array(repeating: DocumentRewriter.coercedVariableTypeWarningCode, count: 2))
    }

    @Test("a read in a removed parameter does not keep the variable from its coercion")
    func removedReadDoesNotBlock() throws {
        let schema = try BoardAPI().schema.schema
        let rules = GraphQLNameRules(
            removedParameters: [GraphQLRemovedParameter(name: "old_column", replacement: "use column.")]
        )

        let rewritten = try DocumentRewriter(for: schema, rules: rules)
            .rewrittenDocument(from: #"mutation($x: String!) { moveTask(input: { id: "t", column: $x, oldColumn: $x }) }"#)

        #expect(rewritten.text.contains("$x: ID!"))
        #expect(
            Set(rewritten.warnings.map(\.code))
                == [GraphQLRemovedParameter.warningCode, DocumentRewriter.coercedVariableTypeWarningCode])
    }

    @Test("a variable read at both an ID and a String position keeps its type, and validation reports it")
    func mixedReadsKeepTheType() async throws {
        let response = try await Self.run(
            #"mutation($x: String!) { moveTask(input: { id: $x }) tagTasks(ids: ["a"], tag: $x) }"#,
            variables: ["x": "q"]
        )

        #expect(try ResponseJSON.codes(response) == ["GRAPHQL_VALIDATION_FAILED"])
        #expect(try ResponseJSON.warningCodes(response).isEmpty)
    }

    @Test("a String variable at a String position gives no warning")
    func matchingTypeGivesNoWarning() async throws {
        let response = try await Self.run(
            #"mutation($tag: String!) { tagTasks(ids: ["a"], tag: $tag) }"#,
            variables: ["tag": "bug"]
        )

        #expect(try ResponseJSON.codes(response).isEmpty)
        #expect(try ResponseJSON.warningCodes(response).isEmpty)
    }
}
