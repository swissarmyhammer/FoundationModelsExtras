import Foundation
import Graphiti
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// Proves the response conventions of the toolkit: the coded errors, the warnings, the `DateTime` and `JSON`
/// scalars, and the `extensions` of a response.
@Suite("GraphQL response conventions")
struct GraphQLResponseConventionTests {
    // MARK: - Coded errors

    @Test(
        "each toolkit error has its fixed code",
        arguments: [
            (GraphQLToolkitError.invalidVariables(received: "a number"), "INVALID_VARIABLES"),
            (.subscriptionNotInTool(hint: nil), "SUBSCRIPTION_NOT_IN_TOOL"),
            (.graphQLParseFailed(detail: "x"), "GRAPHQL_PARSE_FAILED"),
            (.graphQLValidationFailed(detail: "x"), "GRAPHQL_VALIDATION_FAILED"),
            (.ambiguousName(name: "n", matches: ["a", "b"]), "AMBIGUOUS_NAME"),
            (.internalFailure(detail: "x"), "INTERNAL"),
            (.notFound(kind: "note", id: "n9"), "NOT_FOUND"),
            (.resyncRequired(reason: "x"), "RESYNC_REQUIRED"),
        ]
    )
    func eachToolkitErrorHasItsCode(error: GraphQLToolkitError, code: String) {
        #expect(error.code == code)
    }

    @Test("the not found error names the id, and tells the caller to query the state again")
    func notFoundNamesTheID() {
        let error = GraphQLToolkitError.notFound(kind: "note", id: "n9")

        #expect(
            error.message
                == "No note has the id \"n9\". Query the state again to get the current ids, "
                + "then send the call with one of them.")
    }

    @Test("the resync error gives the reason, and tells the caller to query the state again and subscribe again")
    func resyncRequiredTellsHowToResume() {
        let error = GraphQLToolkitError.resyncRequired(reason: "The cursor is from another run.")

        #expect(
            error.message
                == "The cursor is from another run. The changes after the cursor are lost. Query the state again, "
                + "then subscribe with the new cursor.")
    }

    @Test("the subscription error gives the hint of the tool, or the general text")
    func subscriptionErrorGivesTheHint() {
        #expect(
            GraphQLToolkitError.subscriptionNotInTool(hint: "Poll the history.").message
                == "The tool does not run a subscription. Poll the history.")
        #expect(
            GraphQLToolkitError.subscriptionNotInTool(hint: nil).message
                == "The tool does not run a subscription. Send a query or a mutation.")
    }

    @Test("the ambiguous name error lists the matches")
    func ambiguousNameListsTheMatches() {
        let error = GraphQLToolkitError.ambiguousName(name: "taskz", matches: ["task", "tasks"])

        #expect(error.message == "The name \"taskz\" matches more than one name: task, tasks. Use one of these names.")
    }

    @Test("a coded GraphQL error keeps its path and its other extensions, and gets the message and the code")
    func codedErrorKeepsPathAndExtensions() {
        let error = GraphQLError(
            message: "engine text",
            path: ["deleteNote"],
            extensions: ["hint": .string("kept")]
        )

        let coded = error.coded(as: NoteNotFound(id: "n9"))

        #expect(coded.message == NoteNotFound(id: "n9").message)
        #expect(coded.extensions["code"] == .string("NOT_FOUND"))
        #expect(coded.extensions["hint"] == .string("kept"))
        #expect(coded.path.elements == [IndexPathValue.key("deleteNote")])
    }

    @Test("a result error is coded by its kind: a package error, a validation error, or a fault")
    func resultErrorIsCodedByItsKind() {
        let packageError = GraphQLError(message: "x", originalError: NoteNotFound(id: "n9"))
        let validation = GraphQLError(message: "Cannot query field \"nope\".")
        let fault = GraphQLError(message: "boom", path: ["fault"])

        #expect(packageError.codedAsResultError().extensions["code"] == .string("NOT_FOUND"))
        #expect(validation.codedAsResultError().extensions["code"] == .string("GRAPHQL_VALIDATION_FAILED"))
        #expect(validation.codedAsResultError().message == "Cannot query field \"nope\".")
        #expect(fault.codedAsResultError().extensions["code"] == .string("INTERNAL"))
    }

    @Test("a parse failure keeps the code of a coded error that it holds")
    func parseFailureKeepsACodedError() {
        let plain = GraphQLError(message: "Syntax Error")
        let holding = GraphQLError(message: "x", originalError: NoteNotFound(id: "n9"))

        #expect(plain.codedAsParseFailure().extensions["code"] == .string("GRAPHQL_PARSE_FAILED"))
        #expect(holding.codedAsParseFailure().extensions["code"] == .string("NOT_FOUND"))
    }

    @Test("the error-only response has the error, and the warnings only when there are some")
    func errorOnlyResponseHasTheWarningsWhenThereAreSome() throws {
        let error = GraphQLToolkitError.invalidVariables(received: "a number")
        let warning = ResponseWarning(message: "a/b was ignored.", code: "IGNORED")

        let plain = try error.responseJSON()
        let withWarning = try error.responseJSON(warnings: [warning])

        let plainObject = try ResponseJSON.object(plain)
        let plainErrors = plainObject["errors"] as? [[String: Any]] ?? []
        #expect(Set(plainObject.keys) == ["errors"])
        #expect(plainErrors.first?["message"] as? String == error.message)
        #expect((plainErrors.first?["path"] as? [Any])?.isEmpty == true)
        #expect(try ResponseJSON.codes(plain) == ["INVALID_VARIABLES"])
        #expect(try ResponseJSON.codes(withWarning) == ["INVALID_VARIABLES"])
        #expect(try ResponseJSON.warningCodes(withWarning) == ["IGNORED"])
        #expect(withWarning.contains("a/b was ignored."))
    }

    @Test("the path of an error JSON writes a key as a string and an index as a number")
    func errorPathWritesKeysAndIndexes() throws {
        let json = CodedErrorJSON(NoteNotFound(id: "n9"), at: [.key("notes"), .index(2)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let text = String(decoding: try encoder.encode(json), as: UTF8.self)
        let decoded = try JSONDecoder().decode(CodedErrorJSON.self, from: Data(text.utf8))

        #expect(text.contains(#""path":["notes",2]"#))
        #expect(decoded == json)
    }

    // MARK: - Warnings

    @Test("the warnings of a run keep the order of the adds")
    func warningsKeepTheOrderOfTheAdds() async {
        let warnings = ResponseWarnings()

        await warnings.add("first", code: "A")
        await warnings.add(contentsOf: [ResponseWarning(message: "second"), ResponseWarning(message: "third")])

        #expect(await warnings.list.map(\.message) == ["first", "second", "third"])
        #expect(await warnings.list.map(\.code) == ["A", nil, nil])
    }

    @Test("the resolver warnings of a run move into the warnings of the run, with no repeat")
    func resolverWarningsMoveWithNoRepeat() async throws {
        let warnings = ResponseWarnings()

        let value = try await ResolverWarnings.collecting(into: warnings) {
            ResolverWarnings.current?.add(ResponseWarning(message: "once", code: "W"))
            ResolverWarnings.current?.add(ResponseWarning(message: "once", code: "W"))
            return 7
        }
        ResolverWarnings.current?.add(ResponseWarning(message: "after the run"))

        #expect(value == 7)
        #expect(await warnings.list == [ResponseWarning(message: "once", code: "W")])
    }

    // MARK: - Scalars

    @Test("a DateTime round-trips through its RFC 3339 text with milliseconds")
    func dateTimeRoundTrips() throws {
        let text = "2026-10-06T14:49:10.690Z"

        let time = try DateTime(rfc3339: text)

        #expect(time.rfc3339 == text)
        #expect(try DateTime(rfc3339: time.rfc3339) == time)
        #expect(DateTime(time.date) == time)
    }

    @Test("a DateTime before 1970 has a millisecond part from 0 to 999")
    func dateTimeBefore1970() {
        let time = DateTime(millisecondsSince1970: -1)

        #expect(time.rfc3339 == "1969-12-31T23:59:59.999Z")
    }

    @Test("a DateTime keeps one millisecond, and orders by time")
    func dateTimeKeepsOneMillisecond() {
        let first = DateTime(millisecondsSince1970: 1)

        #expect(first.rfc3339 == "1970-01-01T00:00:00.001Z")
        #expect(DateTime(millisecondsSince1970: 0) < first)
    }

    @Test("text that is not RFC 3339 gives an error with the text")
    func dateTimeRejectsOtherText() {
        #expect(throws: DateTimeError.notRFC3339("yesterday")) {
            try DateTime(rfc3339: "yesterday")
        }
    }

    @Test("the JSON scalar sorts the keys of each object, and keeps a Bool")
    func jsonScalarSortsKeysAndKeepsBools() throws {
        let value: Map = .dictionary(["b": .bool(true), "a": .array([.dictionary(["z": 1, "y": 2])])])

        let canonical = JSONScalar.canonical(value)

        #expect(canonical.dictionary.map { Array($0.keys) } == ["a", "b"])
        #expect(canonical.dictionary?["b"] == .bool(true))
        #expect(canonical.dictionary?["a"]?.array?.first?.dictionary.map { Array($0.keys) } == ["y", "z"])
    }

    @Test("the JSON scalar refuses an output value that is not a Map")
    func jsonScalarRefusesANonMap() {
        #expect(throws: JSONScalarError.notAMap("Int")) {
            try JSONScalar.serialize(3, coders: Coders())
        }
    }

    @Test("the example endpoint gives a DateTime and a JSON value through the schema")
    func endpointGivesScalars() async throws {
        let endpoint = try ExampleGraph()

        let response = try await endpoint.execute(
            query: #"{ now echo(value: {b: true, a: [1, "x"]}) }"#,
            variables: [:],
            operationName: nil,
            viewer: nil
        )

        #expect(response == #"{"data":{"echo":{"a":[1,"x"],"b":true},"now":"\#(ExampleGraph.now.rfc3339)"}}"#)
    }

    // MARK: - Response extensions

    @Test("a response with no rewrite, no warning and no more key has no extensions")
    func responseWithNothingHasNoExtensions() throws {
        let response = GraphQLResponse(result: GraphQLResult(data: ["a": 1]))

        #expect(try response.json(formattedWith: .sortedKeys) == #"{"data":{"a":1}}"#)
    }

    @Test("a response writes the rewrites, the warnings, and the more keys of extensions")
    func responseWritesTheExtensions() throws {
        let response = GraphQLResponse(
            result: GraphQLResult(data: ["a": 1]),
            rewrites: [NameRewrite(from: "A", to: "a", path: ["A"])],
            warnings: [ResponseWarning(message: "w", code: "W")],
            extensions: ["txn": "01K", "rewrites": "taken", "warnings": "taken"]
        )

        let text = try response.json(formattedWith: .sortedKeys)

        #expect(
            text
                == #"{"data":{"a":1},"extensions":{"rewrites":[{"from":"A","path":["A"],"to":"a"}],"#
                + #""txn":"01K","warnings":[{"code":"W","message":"w"}]}}"#)
    }

    @Test("an endpoint with a transaction gives extensions.txn from its context")
    func endpointGivesTheTransaction() async throws {
        let endpoint = try ExampleGraph(transaction: "01KTXN")

        let response = try await endpoint.execute(query: "{ ping }", variables: [:], operationName: nil, viewer: nil)
        let extensions = try ResponseJSON.object(response)["extensions"] as? [String: Any]

        #expect(extensions?["txn"] as? String == "01KTXN")
        #expect(try ResponseJSON.warningCodes(response) == ["PING"])
    }
}
