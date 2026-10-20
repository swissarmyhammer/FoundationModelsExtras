import Foundation
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// Proves the forgiving name rewrite and the engine run of the toolkit through the example endpoint: the rewrites in
/// `extensions.rewrites`, the root container, the removed parameters, the keys of the variables, a JSON list in a
/// string, the ties, the list of the canonical names, and the codes of the errors.
@Suite("Name rewrite and engine run")
struct NameRewriteTests {
    /// Runs one document against the example endpoint.
    ///
    /// - Parameters:
    ///   - query: The document.
    ///   - variables: The values of the variables.
    /// - Returns: The response JSON text.
    static func run(_ query: String, variables: [String: Map] = [:]) async throws -> String {
        try await ExampleGraph().execute(query: query, variables: variables, operationName: nil, viewer: nil)
    }

    /// Gives the `data` of a response.
    static func data(_ response: String) throws -> [String: Any] {
        try #require(try ResponseJSON.object(response)["data"] as? [String: Any])
    }

    /// Gives the messages of the errors of a response.
    static func messages(_ response: String) throws -> [String] {
        let errors = try ResponseJSON.object(response)["errors"] as? [[String: Any]] ?? []
        return errors.compactMap { error in error["message"] as? String }
    }

    @Test("a document with only canonical names gives no rewrite and no extensions")
    func canonicalNamesGiveNoRewrite() async throws {
        let response = try await Self.run(#"{ shelf { note(id: "n1") { title body } } }"#)

        #expect(response == #"{"data":{"shelf":{"note":{"body":"The first note.","title":"First"}}}}"#)
    }

    @Test("a field alias keeps the response key of the caller, and the rewrite shows in extensions.rewrites")
    func fieldAliasKeepsTheResponseKey() async throws {
        let response = try await Self.run(#"{ shelf { note(id: "n1") { Title description status } } }"#)
        let note = try #require(((try Self.data(response))["shelf"] as? [String: Any])?["note"] as? [String: Any])

        #expect(note["Title"] as? String == "First")
        #expect(note["description"] as? String == "The first note.")
        #expect(note["status"] as? String == "OPEN")
        #expect(try ResponseJSON.rewrites(response) == ["Title→title", "description→body", "status→state"])
    }

    @Test("an alias of an argument at its field coordinate gives the argument")
    func argumentAliasAtItsCoordinate() async throws {
        let response = try await Self.run("{ shelf { notes(limit: 1) { id } } }")

        #expect(try ResponseJSON.rewrites(response) == ["limit→first"])
        #expect(try ResponseJSON.codes(response).isEmpty)
    }

    @Test("a mutation verb synonym and the other word order give the mutation")
    func mutationVerbSynonym() async throws {
        let response = try await Self.run(#"mutation { noteCreate(input: {title: "T", body: "B"}) { id } }"#)

        #expect((try Self.data(response))["noteCreate"] as? [String: Any] != nil)
        #expect(try ResponseJSON.rewrites(response) == ["noteCreate→addNote"])
    }

    @Test("a root query field moves into the root container, and the result comes back to the root")
    func rootQueryFieldMovesIntoTheContainer() async throws {
        let response = try await Self.run(#"{ getNote(id: "n1") { title } notes { id } }"#)
        let data = try Self.data(response)

        #expect(Set(data.keys) == ["getNote", "notes"])
        #expect((data["getNote"] as? [String: Any])?["title"] as? String == "First")
        #expect(try ResponseJSON.rewrites(response) == ["getNote→shelf.note", "notes→shelf.notes"])
    }

    @Test("with no root container in the rules, a root query field of the container does not move")
    func noContainerNoMove() throws {
        let schema = try ExampleAPI().schema.schema

        let rewritten = try DocumentRewriter(for: schema, rules: .standard).rewrittenDocument(from: "{ notes { id } }")

        #expect(rewritten.text == "{ notes { id } }")
        #expect(rewritten.rewrites.isEmpty)
    }

    @Test("a removed parameter goes out with its unread variable, and the response gives its warning")
    func removedParameterGoesOut() async throws {
        let response = try await Self.run(
            "query($hide: Boolean) { shelf { notes(first: 1, excludeDone: $hide) { id } } }",
            variables: ["hide": true]
        )

        #expect(try ResponseJSON.codes(response).isEmpty)
        #expect(try ResponseJSON.warningCodes(response) == [GraphQLRemovedParameter.warningCode])
        #expect(response.contains("`excludeDone` is removed, use the state field. The call ignored it."))
    }

    @Test("a removed parameter that is the only argument takes the parentheses out too")
    func removedOnlyArgumentTakesTheParenthesesOut() throws {
        let schema = try ExampleAPI().schema.schema

        let rewritten = try DocumentRewriter(for: schema, rules: ExampleGraph.rules)
            .rewrittenDocument(from: "{ shelf { notes(EXCLUDE_DONE: true) { id } } }")

        #expect(rewritten.text == "{ shelf { notes { id } } }")
        #expect(rewritten.warnings.map(\.code) == [GraphQLRemovedParameter.warningCode])
    }

    @Test("the keys of an input object in the variables get their canonical names")
    func variableKeysGetCanonicalNames() async throws {
        let response = try await Self.run(
            "mutation($input: AddNoteInput!) { addNote(input: $input) { title body tags } }",
            variables: ["input": ["Title": "T", "content": "B", "TAGS": #"["x","y"]"#]]
        )
        let note = try #require((try Self.data(response))["addNote"] as? [String: Any])

        #expect(note["title"] as? String == "T")
        #expect(note["body"] as? String == "B")
        #expect(note["tags"] as? [String] == ["x", "y"])
        #expect(try ResponseJSON.rewrites(response) == ["Title→title", "content→body", "TAGS→tags"])
    }

    @Test("a JSON list in a string literal at a list position gives the items")
    func jsonListInAStringLiteral() async throws {
        let response = try await Self.run(#"mutation { addNote(input: {title: "T", tags: "[\"x\",\"y\"]"}) { tags } }"#)
        let note = try #require((try Self.data(response))["addNote"] as? [String: Any])

        #expect(note["tags"] as? [String] == ["x", "y"])
        #expect(try ResponseJSON.warningCodes(response) == ["NO_BODY"])
    }

    @Test("an enum value in a different case gives the canonical value")
    func enumValueCase() async throws {
        let response = try await Self.run(#"mutation { addNote(input: {title: "T", state: closed}) { state } }"#)

        #expect(((try Self.data(response))["addNote"] as? [String: Any])?["state"] as? String == "CLOSED")
        #expect(try ResponseJSON.rewrites(response) == ["closed→CLOSED"])
    }

    @Test("a name with a tie gives AMBIGUOUS_NAME, and the document does not run")
    func tieGivesAmbiguousName() async throws {
        let response = try await Self.run(#"{ shelf { notez { id } } }"#)

        #expect(try ResponseJSON.codes(response) == ["AMBIGUOUS_NAME"])
        #expect(try ResponseJSON.object(response)["data"] == nil)
        #expect(try Self.messages(response).first?.contains("note, notes") == true)
    }

    @Test("a name with no match gives the validation error with the list of the canonical names")
    func noMatchGivesTheListOfNames() async throws {
        let response = try await Self.run(#"{ shelf { note(id: "n1") { frobnicate } } }"#)

        #expect(try ResponseJSON.codes(response) == ["GRAPHQL_VALIDATION_FAILED"])
        #expect(
            try Self.messages(response).first?.hasSuffix("The fields of Note are: id, title, body, tags, state.")
                == true)
    }

    @Test("an error has its location in the text of the caller, not in the rewritten text")
    func errorLocationIsInTheTextOfTheCaller() async throws {
        let response = try await Self.run(#"{ getNote(id: "n1") { frobnicate } }"#)
        let errors = try ResponseJSON.object(response)["errors"] as? [[String: Any]] ?? []
        let location = (errors.first?["locations"] as? [[String: Int]])?.first

        #expect(location == ["line": 1, "column": 23])
    }

    @Test("a coded resolver error keeps its code, and the field is null")
    func codedResolverError() async throws {
        let response = try await Self.run(#"mutation { deleteNote(id: "n9") { id } }"#)

        #expect(try ResponseJSON.codes(response) == ["NOT_FOUND"])
        #expect(try Self.messages(response) == [NoteNotFound(id: "n9").message])
        #expect((try Self.data(response))["deleteNote"] is NSNull)
    }

    @Test("a resolver fault that is not a coded error gives INTERNAL")
    func faultGivesInternal() async throws {
        let response = try await Self.run("{ fault }")

        #expect(try ResponseJSON.codes(response) == ["INTERNAL"])
    }

    @Test("a document that does not parse gives GRAPHQL_PARSE_FAILED and no data")
    func parseFailure() async throws {
        let response = try await Self.run("{ shelf {")

        #expect(try ResponseJSON.codes(response) == ["GRAPHQL_PARSE_FAILED"])
        #expect(try ResponseJSON.object(response)["data"] == nil)
    }

    @Test("a subscription that cannot start gives one response with the errors, and the stream ends")
    func subscriptionThatCannotStart() async throws {
        let endpoint = try ExampleGraph()

        for document in ["subscription {", "subscription { notez }", "subscription { ping }"] {
            let stream = try await endpoint.subscribe(
                query: document,
                variables: [:],
                operationName: nil,
                viewer: nil
            )
            var responses: [String] = []
            for try await response in stream {
                responses.append(response)
            }

            #expect(responses.count == 1)
            #expect(try !ResponseJSON.codes(try #require(responses.first)).isEmpty)
        }
    }
}
