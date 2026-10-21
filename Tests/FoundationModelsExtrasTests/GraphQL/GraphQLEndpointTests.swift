import Foundation
import FoundationModels
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// Proves the endpoint protocol, its description on the wire, the viewer of a call, and the discovery of the
/// endpoints of a tool through ``GraphQLEndpointTool``.
@Suite("GraphQL endpoint, viewer, and endpoint tool")
struct GraphQLEndpointTests {
    /// The arguments of the test tools.
    @Generable
    struct PlainArguments {
        /// A value that the tool gives back.
        let value: String
    }

    /// A tool that gives a list of endpoints.
    struct EndpointsTool: GraphQLEndpointTool {
        let name = "endpoints"
        let description = "gives its endpoints"

        /// The endpoints of the tool.
        let graphQLEndpoints: [any GraphQLEndpoint]

        func call(arguments: PlainArguments) async throws -> String {
            arguments.value
        }
    }

    /// A tool that gives no endpoint.
    struct PlainTool: Tool {
        let name = "plain"
        let description = "gives no endpoint"

        func call(arguments: PlainArguments) async throws -> String {
            arguments.value
        }
    }

    @Test("the scope raw values are the wire values of the tunnel")
    func scopeRawValuesAreTheWireValues() {
        #expect(GraphQLEndpointScope.sessionFolder.rawValue == "sessionFolder")
        #expect(GraphQLEndpointScope.server.rawValue == "server")
    }

    @Test("the description of an endpoint encodes to name, version, scope and schema")
    func descriptionEncodesTheWireShape() throws {
        let endpoint = try ExampleGraph()

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(endpoint.endpointDescription)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(Set(object.keys) == ["name", "version", "scope", "schema"])
        #expect(object["name"] == ExampleGraph.endpointName)
        #expect(object["version"] == "1")
        #expect(object["scope"] == "sessionFolder")
        #expect(object["schema"] == endpoint.schema)
    }

    @Test("the description decodes from the wire shape")
    func descriptionDecodesTheWireShape() throws {
        let json = #"{"name":"agents","version":"2","scope":"server","schema":"type Query { a: String }"}"#

        let description = try JSONDecoder().decode(GraphQLEndpointDescription.self, from: Data(json.utf8))

        #expect(
            description
                == GraphQLEndpointDescription(
                    name: "agents",
                    version: "2",
                    scope: .server,
                    schema: "type Query { a: String }"
                ))
    }

    @Test("the viewer of a call owns its sessions, and each owned session is also client owned")
    func viewerOwnsItsSessions() {
        let viewer = GraphQLViewer(
            clientId: "ipad",
            trust: .external,
            ownedSessions: ["s1"],
            clientOwnedSessions: ["s2"]
        )

        #expect(viewer.owns("s1"))
        #expect(!viewer.owns("s2"))
        #expect(viewer.clientOwnedSessions == ["s1", "s2"])
        #expect(GraphQLViewer.Trust.userDevice.rawValue == "userDevice")
        #expect(GraphQLViewer.Trust.external.rawValue == "external")
    }

    @Test("a viewer starts no session when the caller gives none")
    func viewerStartedSessionsDefaultToEmpty() {
        let viewer = GraphQLViewer(clientId: "ipad", trust: .external, ownedSessions: ["s1"])

        #expect(viewer.startedSessions.isEmpty)
    }

    @Test("the started sessions of a viewer survive an encode and decode")
    func viewerStartedSessionsRoundTrip() throws {
        let viewer = GraphQLViewer(
            clientId: "ipad",
            trust: .external,
            ownedSessions: ["s1"],
            clientOwnedSessions: ["s2"],
            startedSessions: ["s1", "s3"]
        )

        let decoded = try JSONDecoder().decode(GraphQLViewer.self, from: try JSONEncoder().encode(viewer))

        #expect(decoded == viewer)
        #expect(decoded.startedSessions == ["s1", "s3"])
    }

    @Test("a viewer encoded before started sessions decodes with none")
    func viewerWithNoStartedSessionsKeyDecodes() throws {
        let json = #"{"clientId":"ipad","trust":"external","ownedSessions":["s1"],"clientOwnedSessions":["s1","s2"]}"#

        let viewer = try JSONDecoder().decode(GraphQLViewer.self, from: Data(json.utf8))

        #expect(viewer.startedSessions.isEmpty)
        #expect(viewer == GraphQLViewer(clientId: "ipad", trust: .external, ownedSessions: ["s1"], clientOwnedSessions: ["s2"]))
    }

    @Test("the endpoint gives the viewer of the call to its resolvers, and no viewer is the agent")
    func endpointGivesTheViewerToItsResolvers() async throws {
        let endpoint = try ExampleGraph()
        let viewer = GraphQLViewer(clientId: "mac", trust: .userDevice)

        let fromClient = try await endpoint.execute(
            query: "{ viewer }",
            variables: [:],
            operationName: nil,
            viewer: viewer
        )
        let fromAgent = try await endpoint.execute(query: "{ viewer }", variables: [:], operationName: nil, viewer: nil)

        #expect(fromClient == #"{"data":{"viewer":"userDevice"}}"#)
        #expect(fromAgent == #"{"data":{"viewer":"agent"}}"#)
    }

    @Test("a host finds the endpoints of a tool through its any Tool value")
    func hostFindsTheEndpointsOfATool() throws {
        let endpoint = try ExampleGraph()
        let tools: [any Tool] = [
            EndpointsTool(graphQLEndpoints: [endpoint]),
            EndpointsTool(graphQLEndpoints: []),
            EndpointsTool(graphQLEndpoints: [endpoint, endpoint]),
            PlainTool(),
        ]

        let counts = tools.map { tool in (tool as? any GraphQLEndpointTool)?.graphQLEndpoints.count }

        #expect(counts == [1, 0, 2, nil])
        #expect((tools[0] as? any GraphQLEndpointTool)?.graphQLEndpoints.first?.name == ExampleGraph.endpointName)
    }
}
