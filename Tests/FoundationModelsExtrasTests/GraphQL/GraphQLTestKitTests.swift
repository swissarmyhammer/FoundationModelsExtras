import Foundation
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// Proves the test kit of the toolkit: the SDL golden file, the schema descriptions, and the endpoint conformance.
@Suite("GraphQL test kit")
struct GraphQLTestKitTests {
    /// An endpoint that breaks the conventions: a scope that the check does not expect, an empty version, no
    /// rewrite for the alias probe, and plain errors with no code.
    struct NonConformingEndpoint: GraphQLEndpoint {
        let name = "broken"
        let version = " "
        let scope = GraphQLEndpointScope.server
        let schema = "type Query { a: String }"

        func execute(
            query: String,
            variables _: [String: Map],
            operationName _: String?,
            viewer _: GraphQLViewer?
        ) async throws -> String {
            query.contains("__typename")
                ? #"{"data":{"__typename":"Query"}}"#
                : #"{"data":{"a":null},"errors":[{"message":"no"}]}"#
        }

        func subscribe(
            query _: String,
            variables _: [String: Map],
            operationName _: String?,
            viewer _: GraphQLViewer?
        ) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in continuation.finish() }
        }
    }

    /// An endpoint whose subscriptions start and then send nothing, and stay open.
    struct SilentSubscriptionEndpoint: GraphQLEndpoint {
        let name = "silent"
        let version = "1"
        let scope = GraphQLEndpointScope.server
        let schema = "type Query { a: String } type Subscription { changes: String }"

        func execute(
            query _: String,
            variables _: [String: Map],
            operationName _: String?,
            viewer _: GraphQLViewer?
        ) async throws -> String {
            #"{"data":{"__typename":"Query"}}"#
        }

        func subscribe(
            query _: String,
            variables _: [String: Map],
            operationName _: String?,
            viewer _: GraphQLViewer?
        ) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { _ in }
        }
    }

    /// The codes of the example endpoint, for rule 8.
    static let exampleCodes = ["NOT_FOUND", "NO_BODY", "PING"]

    @Test("the example endpoint built from the toolkit conforms, with its alias probe")
    func exampleEndpointConforms() async throws {
        let problems = await GraphQLEndpointConformance.problems(
            of: try ExampleGraph(),
            scope: .sessionFolder,
            probe: ExampleGraph.aliasProbe,
            codes: Self.exampleCodes
        )

        #expect(problems == [])
    }

    @Test("the example endpoint conforms with a query alias probe and a subscription alias probe in one call")
    func exampleEndpointConformsWithASubscriptionProbe() async throws {
        let endpoint = try ExampleGraph()

        let problems = await GraphQLEndpointConformance.problems(
            of: endpoint,
            scope: .sessionFolder,
            probes: [ExampleGraph.aliasProbe, await endpoint.changesProbe()],
            codes: Self.exampleCodes
        )

        #expect(problems == [])
    }

    @Test("a subscription alias that the endpoint does not rewrite gives a problem that names the probe")
    func unrewrittenSubscriptionAliasGivesAProblem() async throws {
        let endpoint = try ExampleGraph()
        let probe = await endpoint.changesProbe(writing: "agentChanges")

        let problems = await GraphQLEndpointConformance.problems(
            of: endpoint,
            scope: .sessionFolder,
            probes: [probe],
            codes: Self.exampleCodes
        )

        #expect(
            problems.contains(
                "The subscription alias probe \(probe.query) gave no rewrite from agentChanges to changes in "
                    + "extensions.rewrites."))
    }

    @Test("a subscription that sends no first response gives a problem when the wait ends, and does not hang")
    func silentSubscriptionGivesAProblem() async {
        let clock = ManualRunClock()
        let probe = GraphQLAliasProbe(
            query: "subscription { changes }",
            from: "changes",
            to: "changes",
            kind: .subscription
        )
        let limit = GraphQLEndpointConformance.firstResponseLimit
        let checking = Task {
            await GraphQLEndpointConformance.problems(
                of: SilentSubscriptionEndpoint(),
                scope: .server,
                probes: [probe],
                clock: clock
            )
        }

        // The document that does not parse waits first, then the probe.
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: limit)
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: limit)
        let problems = await checking.value

        #expect(problems.contains("A subscription document that does not parse gave no response within \(limit)."))
        #expect(problems.contains("The subscription alias probe \(probe.query) gave no response within \(limit)."))
    }

    @Test("a subscription that ends with no response gives a problem for the probe")
    func endedSubscriptionGivesAProblem() async {
        let probe = GraphQLAliasProbe(query: "subscription { A }", from: "A", to: "a", kind: .subscription)

        let problems = await GraphQLEndpointConformance.problems(
            of: NonConformingEndpoint(),
            scope: .server,
            probes: [probe]
        )

        #expect(problems.contains("The subscription alias probe \(probe.query) gave no response."))
    }

    @Test("an endpoint that breaks the conventions gives a problem for each break")
    func nonConformingEndpointGivesProblems() async {
        let problems = await GraphQLEndpointConformance.problems(
            of: NonConformingEndpoint(),
            scope: .sessionFolder,
            probe: GraphQLAliasProbe(query: "{ A }", from: "A", to: "a")
        )

        #expect(problems.contains("The version is empty."))
        #expect(problems.contains("The scope is server, not sessionFolder."))
        #expect(problems.contains { $0.hasPrefix("A document that does not parse gave the codes []") })
        #expect(problems.contains { $0.hasPrefix("A subscription document that does not parse gave no response") })
        #expect(problems.contains { $0.contains("gave no rewrite from A to a in extensions.rewrites") })
        #expect(!problems.contains { $0.hasPrefix("The call { __typename }") })
    }

    @Test("an SDL that does not build is a problem")
    func brokenSDLIsAProblem() async {
        struct BrokenSDL: GraphQLEndpoint {
            let name = "sdl"
            let version = "1"
            let scope = GraphQLEndpointScope.server
            let schema = "type Query {"

            func execute(
                query _: String,
                variables _: [String: Map],
                operationName _: String?,
                viewer _: GraphQLViewer?
            ) async throws -> String { "{}" }

            func subscribe(
                query _: String,
                variables _: [String: Map],
                operationName _: String?,
                viewer _: GraphQLViewer?
            ) async throws -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { continuation in continuation.finish() }
            }
        }

        let problems = await GraphQLEndpointConformance.problems(
            of: BrokenSDL(),
            scope: .server,
            probe: GraphQLAliasProbe(query: "{ a }", from: "A", to: "a")
        )

        #expect(problems.contains { $0.hasPrefix("The SDL schema does not build") })
    }

    @Test("each part with no description is listed, and a described schema gives none")
    func schemaDescriptions() throws {
        let bare = try buildSchema(
            source: """
                type Query { note(id: ID): Note }
                type Note { title: String }
                enum State { OPEN }
                input NoteInput { title: String }
                """
        )
        let described = try buildSchema(
            source: #"""
                "The root."
                type Query {
                  "One note."
                  note("The id." id: ID): Note
                }
                "A note."
                type Note {
                  "The title."
                  title: String
                }
                """#
        )

        #expect(
            try GraphQLSchemaDescriptions.undescribed(in: bare)
                == ["Query.note", "Query.note(id:)", "Note", "Note.title", "State", "State.OPEN", "NoteInput",
                    "NoteInput.title"])
        #expect(try GraphQLSchemaDescriptions.undescribed(in: described) == [])
    }

    @Test("the example schema has a description on each part")
    func exampleSchemaIsDescribed() throws {
        let undescribed = try GraphQLSchemaDescriptions.undescribed(in: ExampleAPI().schema.schema)

        #expect(undescribed == [])
    }

    @Test("the golden check passes for the same SDL, reports a change, and records on request")
    func goldenFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let golden = folder.appending(path: "schema.graphql")

        let missing = GraphQLSchemaGolden.problems(of: "type Query { a: String }", against: golden, environment: [:])
        let recorded = GraphQLSchemaGolden.problems(
            of: "type Query { a: String }",
            against: golden,
            environment: [GraphQLSchemaGolden.recordVariable: "1"]
        )
        let same = GraphQLSchemaGolden.problems(of: "type Query { a: String }", against: golden, environment: [:])
        let changed = GraphQLSchemaGolden.problems(of: "type Query { b: String }", against: golden, environment: [:])

        #expect(missing.count == 1)
        #expect(recorded == [])
        #expect(try String(contentsOf: golden, encoding: .utf8) == "type Query { a: String }\n")
        #expect(same == [])
        #expect(changed.count == 1)
        #expect(changed.first?.contains(GraphQLSchemaGolden.recordVariable) == true)
    }
}
