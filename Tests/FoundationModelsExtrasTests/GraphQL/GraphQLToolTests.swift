import Foundation
import FoundationModels
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// Proves the GraphQL tool wrapper: the forgiving decode of its arguments, its errors, and the endpoint that it gives.
@Suite("GraphQL tool wrapper")
struct GraphQLToolTests {
    /// Decodes the arguments of a call from JSON text.
    ///
    /// - Parameter json: The arguments object as JSON text.
    /// - Returns: The arguments.
    static func arguments(_ json: String) throws -> GraphQLArguments {
        try GraphQLArguments(GeneratedContent(json: json))
    }

    /// Makes the tool over the example endpoint.
    static func tool(subscriptionHint: String? = nil) throws -> GraphQLTool {
        GraphQLTool(description: "Reads the notes.", endpoint: try ExampleGraph(), subscriptionHint: subscriptionHint)
    }

    @Test(
        "the variables decode from an object, a JSON string, or a fenced JSON string",
        arguments: [
            #"{"query": "q", "variables": {"id": "n1"}}"#,
            #"{"query": "q", "variables": "{\"id\": \"n1\"}"}"#,
            #"{"query": "q", "variables": "```json\n{\"id\": \"n1\"}\n```"}"#,
        ]
    )
    func variablesDecodeFromEachForm(json: String) throws {
        let arguments = try Self.arguments(json)

        #expect(arguments.variables == ["id": "n1"])
        #expect(arguments.variablesError == nil)
    }

    @Test(
        "no variables, null, an empty object, and an empty string give no variables",
        arguments: [
            #"{"query": "q"}"#, #"{"query": "q", "variables": null}"#, #"{"query": "q", "variables": {}}"#,
            #"{"query": "q", "variables": ""}"#,
        ]
    )
    func emptyVariables(json: String) throws {
        let arguments = try Self.arguments(json)

        #expect(arguments.variables.isEmpty)
        #expect(arguments.variablesError == nil)
    }

    @Test(
        "variables that are not a JSON object set the error and do not throw",
        arguments: [
            (#"{"query": "q", "variables": 3}"#, "a number"),
            (#"{"query": "q", "variables": [1]}"#, "a list"),
            (#"{"query": "q", "variables": "not json"}"#, "text that is not JSON"),
            (#"{"query": "q", "variables": "[1]"}"#, "text that holds a list"),
        ]
    )
    func invalidVariables(json: String, received: String) throws {
        #expect(try Self.arguments(json).variablesError == received)
    }

    @Test("a missing query throws, and an empty operation name gives no name")
    func missingQueryAndEmptyOperationName() throws {
        #expect(throws: GraphQLArguments.MissingQueryError.self) {
            try Self.arguments(#"{"variables": {}}"#)
        }
        #expect(try Self.arguments(#"{"query": "q", "operationName": "  "}"#).operationName == nil)
        #expect(try Self.arguments(#"{"query": "q", "operationName": "A"}"#).operationName == "A")
    }

    @Test("the tool answers a document through its endpoint, with no viewer")
    func toolAnswersThroughItsEndpoint() async throws {
        let response = try await Self.tool().call(arguments: GraphQLArguments(query: "{ viewer ping }"))

        #expect(try ResponseJSON.object(response)["data"] as? [String: String] == ["viewer": "agent", "ping": "pong"])
    }

    @Test("the tool gives INVALID_VARIABLES and runs nothing for variables that are not an object")
    func toolGivesInvalidVariables() async throws {
        let response = try await Self.tool().call(arguments: Self.arguments(#"{"query": "{ ping }", "variables": 3}"#))

        #expect(try ResponseJSON.codes(response) == ["INVALID_VARIABLES"])
        #expect(try ResponseJSON.object(response)["data"] == nil)
    }

    @Test("the tool gives SUBSCRIPTION_NOT_IN_TOOL with its hint for a selected subscription")
    func toolRefusesASubscription() async throws {
        let tool = try Self.tool(subscriptionHint: "Poll the notes.")

        let response = try await tool.call(arguments: GraphQLArguments(query: "subscription { ping }"))
        let named = try await tool.call(
            arguments: GraphQLArguments(query: "query A { ping } subscription B { ping }", operationName: "A")
        )

        #expect(try ResponseJSON.codes(response) == ["SUBSCRIPTION_NOT_IN_TOOL"])
        #expect(response.contains("The tool does not run a subscription. Poll the notes."))
        #expect(try ResponseJSON.codes(named).isEmpty)
    }

    @Test("the tool takes the name of its endpoint, and a host finds the endpoint through the tool")
    func toolGivesItsEndpoint() throws {
        let tool: any Tool = try Self.tool()

        let endpoints = (tool as? any GraphQLEndpointTool)?.graphQLEndpoints

        #expect(tool.name == ExampleGraph.endpointName)
        #expect(endpoints?.map(\.name) == [ExampleGraph.endpointName])
    }
}
