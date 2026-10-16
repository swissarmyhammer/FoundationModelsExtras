@testable import FoundationModelsExtras
import Foundation
import Testing
import ULID

/// Exercises the agent path and the source of an ``ElicitationRequest``: the
/// relay of a question from an agent to its parent, and the wire keys of the
/// two values.
@Suite("Elicitation request: the agent path and the source of a relayed question")
struct ElicitationRelayTests {
    /// The form of each form request of this suite.
    private static let schema = ElicitationRequestedSchema(
        properties: ["name": .string(ElicitationStringSchema())], required: ["name"])

    /// The id of each request that a test decodes from JSON.
    private static let recordedId = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    /// Decodes a request from `json`.
    ///
    /// - Parameter json: The JSON text.
    /// - Returns: The request.
    /// - Throws: The error of the decode.
    private static func decode(_ json: String) throws -> ElicitationRequest {
        try JSONDecoder().decode(ElicitationRequest.self, from: Data(json.utf8))
    }

    /// The top-level keys of the JSON of `request`.
    ///
    /// - Parameter request: The request.
    /// - Returns: The keys.
    /// - Throws: The error of the encode, or a failed expectation when the
    ///   JSON is not an object.
    private static func keys(of request: ElicitationRequest) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        return Set(try #require(object as? [String: Any]).keys)
    }

    @Test("a recorded form request with no agentPath and no source key decodes with no agent and no source")
    func aRecordedFormRequestDecodes() throws {
        let request = try Self.decode(
            """
            {"mode": "form", "message": "Your name?", "elicitationId": "\(Self.recordedId)",
             "requestedSchema": {"type": "object", "properties": {"name": {"type": "string"}}}}
            """)

        #expect(request.agentPath.isEmpty)
        #expect(request.source == nil)
        #expect(request.elicitationId.ulidString == Self.recordedId)
    }

    @Test("a recorded URL request with no agentPath and no source key decodes with no agent and no source")
    func aRecordedURLRequestDecodes() throws {
        let request = try Self.decode(
            """
            {"mode": "url", "message": "Sign in", "elicitationId": "\(Self.recordedId)",
             "url": "https://example.com/sign-in"}
            """)

        #expect(request.agentPath.isEmpty)
        #expect(request.source == nil)
        #expect(request.url == URL(string: "https://example.com/sign-in"))
    }

    @Test("a request with an agent path and a source encodes and decodes to the same request")
    func aRequestWithAPathAndASourceRoundTrips() throws {
        let form = ElicitationRequest(
            message: "Your name?", elicitationId: ULID(), requestedSchema: Self.schema,
            agentPath: ["reviewer", "linter"], source: "runCode")
        let url = try ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: #require(URL(string: "https://example.com/sign-in")),
            agentPath: ["reviewer"], source: "github")

        for request in [form, url] {
            let decoded = try JSONDecoder().decode(ElicitationRequest.self, from: JSONEncoder().encode(request))
            #expect(decoded == request)
        }
    }

    @Test("the path and the source go on the wire under the keys agentPath and source")
    func thePathAndTheSourceHaveTheirKeys() throws {
        let request = ElicitationRequest(
            message: "Your name?", elicitationId: ULID(), requestedSchema: Self.schema, agentPath: ["reviewer"],
            source: "runCode")

        let keys = try Self.keys(of: request)

        #expect(keys.isSuperset(of: ["agentPath", "source"]))
    }

    @Test("a request with no agent and no source encodes no agentPath key and no source key")
    func aPlainRequestHasNoNewKeys() throws {
        let request = ElicitationRequest(message: "Your name?", elicitationId: ULID(), requestedSchema: Self.schema)

        let keys = try Self.keys(of: request)

        #expect(keys == ["mode", "message", "elicitationId", "requestedSchema"])
    }

    @Test("two relays put each agent at the front of the path, keep the id and the first source")
    func twoRelaysGiveThePathInOrder() throws {
        let asked = ElicitationRequest(message: "Your name?", elicitationId: ULID(), requestedSchema: Self.schema)

        let atParent = asked.relayed(by: "linter", askedBy: "runCode")
        let atRoot = atParent.relayed(by: "reviewer", askedBy: "start agent")

        #expect(atParent.agentPath == ["linter"])
        #expect(atParent.source == "runCode")
        #expect(atRoot.agentPath == ["reviewer", "linter"])
        #expect(atRoot.source == "runCode")
        #expect(atRoot.elicitationId == asked.elicitationId)
        #expect(atRoot.message == asked.message)
        #expect(atRoot.mode == .form)
        #expect(atRoot.requestedSchema == asked.requestedSchema)
    }

    @Test("a relay of a URL request keeps its URL and its mode")
    func aRelayKeepsTheURL() throws {
        let asked = try ElicitationRequest(
            message: "Sign in", elicitationId: ULID(), url: #require(URL(string: "https://example.com/sign-in")))

        let relayed = asked.relayed(by: "reviewer", askedBy: "github")

        #expect(relayed.mode == .url)
        #expect(relayed.url == asked.url)
        #expect(relayed.requestedSchema == nil)
        #expect(relayed.agentPath == ["reviewer"])
        #expect(relayed.source == "github")
    }

    @Test("a relay of a request that has a source keeps that source")
    func aRelayKeepsAnEarlierSource() {
        let asked = ElicitationRequest(
            message: "Your name?", elicitationId: ULID(), requestedSchema: Self.schema, source: "mcp-server")

        let relayed = asked.relayed(by: "reviewer", askedBy: "runCode")

        #expect(relayed.source == "mcp-server")
        #expect(relayed.agentPath == ["reviewer"])
    }
}
