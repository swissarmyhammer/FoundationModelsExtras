import Foundation
import GraphQL

// The test kit of the GraphQL toolkit. Each check gives a list of problems, and an empty list passes, so that the
// checks need no test framework: a test target calls a check and expects an empty list.

/// The check of an SDL schema against a golden file: the file holds the SDL that a person read and accepted.
///
/// A change of the schema then shows as a change of the golden file in the diff. To write the file again after a
/// change that is correct, run the tests with the environment variable ``recordVariable`` set to `1`.
public enum GraphQLSchemaGolden {
    /// The environment variable that tells the check to write the golden file and pass.
    public static let recordVariable = "GRAPHQL_GOLDEN_RECORD"

    /// Compares an SDL schema with a golden file.
    ///
    /// - Parameters:
    ///   - sdl: The SDL of the schema, for example ``GraphQLEndpoint/schema``.
    ///   - goldenFile: The URL of the golden file.
    ///   - environment: The environment that can ask for a record. The default is the environment of the process.
    /// - Returns: No problem when the file holds the same SDL, or when the environment asks for a record and the
    ///   write works. Else one problem that tells how to accept the change.
    public static func problems(
        of sdl: String,
        against goldenFile: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let text = sdl.hasSuffix("\n") ? sdl : sdl + "\n"
        if environment[recordVariable] == "1" {
            do {
                try FileManager.default.createDirectory(
                    at: goldenFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try text.write(to: goldenFile, atomically: true, encoding: .utf8)
                return []
            } catch {
                return ["The golden file \(goldenFile.path) cannot be written: \(error)."]
            }
        }
        guard let golden = try? String(contentsOf: goldenFile, encoding: .utf8) else {
            return [
                "The golden file \(goldenFile.path) cannot be read. Run the tests with \(recordVariable)=1 to write it."
            ]
        }
        guard golden != text else {
            return []
        }
        return [
            "The schema is not the same as the golden file \(goldenFile.path). Read the change, and run the tests with "
                + "\(recordVariable)=1 to accept it."
        ]
    }
}

/// The check that each part of a schema has a description, because the agent learns the schema with introspection.
public enum GraphQLSchemaDescriptions {
    /// The names of the built-in scalars, which have the descriptions of the GraphQL specification.
    private static let builtInScalars: Set<String> = ["String", "Int", "Float", "Boolean", "ID"]

    /// The start of the name of an introspection type, for example `__Schema`.
    private static let introspectionPrefix = "__"

    /// Gives each part of a schema that has no description: each type, field, argument, `input` field, and enum
    /// value. The introspection types and the built-in scalars are not checked. The root operation types (`Query`,
    /// `Mutation`, and `Subscription`) need no description of their own, because the Graphiti schema builder gives
    /// them none, but their fields and arguments are checked.
    ///
    /// - Parameter schema: The schema.
    /// - Returns: One text for each part with no description, for example `Task.title` or `Query.task(id:)`, in the
    ///   order of the schema.
    /// - Throws: An error from the schema when a type gives no fields.
    public static func undescribed(in schema: GraphQLSchema) throws -> [String] {
        let rootTypes = Set([schema.queryType?.name, schema.mutationType?.name, schema.subscriptionType?.name])
        var missing: [String] = []
        for (name, type) in schema.typeMap
        where !name.hasPrefix(introspectionPrefix) && !builtInScalars.contains(name) {
            if !rootTypes.contains(name), !isDescribed(description(of: type)) {
                missing.append(name)
            }
            missing += try undescribedMembers(of: type, named: name)
        }
        return missing
    }

    /// Gives each member of a type that has no description.
    ///
    /// - Parameters:
    ///   - type: The type.
    ///   - name: The name of the type.
    /// - Returns: The texts of the members with no description.
    /// - Throws: An error from the schema when a type gives no fields.
    private static func undescribedMembers(of type: any GraphQLNamedType, named name: String) throws -> [String] {
        switch type {
        case let object as GraphQLObjectType:
            try undescribed(fields: object.fields(), of: name)
        case let interface as GraphQLInterfaceType:
            try undescribed(fields: interface.fields(), of: name)
        case let input as GraphQLInputObjectType:
            try input.fields().compactMap { field, definition in
                isDescribed(definition.description) ? nil : "\(name).\(field)"
            }
        case let enumType as GraphQLEnumType:
            enumType.values.compactMap { value in isDescribed(value.description) ? nil : "\(name).\(value.name)" }
        default:
            []
        }
    }

    /// Gives each field and each argument of an object type or an interface type that has no description.
    ///
    /// - Parameters:
    ///   - fields: The fields of the type.
    ///   - name: The name of the type.
    /// - Returns: The texts of the fields and the arguments with no description.
    private static func undescribed(fields: GraphQLFieldMap, of name: String) -> [String] {
        fields.flatMap { field, definition in
            let own = isDescribed(definition.description) ? [] : ["\(name).\(field)"]
            let arguments = definition.args.compactMap { argument, value in
                isDescribed(value.description) ? nil : "\(name).\(field)(\(argument):)"
            }
            return own + arguments
        }
    }

    /// Gives the description of a named type.
    ///
    /// - Parameter type: The type.
    /// - Returns: The description, or `nil` for none.
    private static func description(of type: any GraphQLNamedType) -> String? {
        switch type {
        case let scalar as GraphQLScalarType: scalar.description
        case let object as GraphQLObjectType: object.description
        case let interface as GraphQLInterfaceType: interface.description
        case let union as GraphQLUnionType: union.description
        case let enumType as GraphQLEnumType: enumType.description
        case let input as GraphQLInputObjectType: input.description
        default: nil
        }
    }

    /// Tells if a description has text.
    ///
    /// - Parameter description: The description, or `nil`.
    /// - Returns: `true` when the description has a character that is not white space.
    private static func isDescribed(_ description: String?) -> Bool {
        !(description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A call with an alias name that an endpoint must answer, for the conformance check: the document, and the rewrite
/// that the response must report in `extensions.rewrites`.
public struct GraphQLAliasProbe: Sendable {
    /// How the conformance check sends the document of a probe.
    public enum Kind: Sendable {
        /// The check sends the document through `execute`: a query or a mutation.
        case query

        /// The check sends the document through `subscribe`, and reads the first response. The endpoint must send
        /// that response at once, for example from the buffer of a ``ChangeLog`` after the cursor of the document.
        case subscription
    }

    /// A document that names one field, argument, or `input` field by an alias or a different case.
    public var query: String

    /// The values of the variables of the document.
    public var variables: [String: Map]

    /// The name that the document wrote.
    public var from: String

    /// The canonical name that the rewrite must give.
    public var to: String

    /// How the check sends the document.
    public var kind: Kind

    /// Makes a probe.
    ///
    /// - Parameters:
    ///   - query: A document that names one field, argument, or `input` field by an alias.
    ///   - variables: The values of the variables of the document.
    ///   - from: The name that the document wrote.
    ///   - to: The canonical name that the rewrite must give.
    ///   - kind: How the check sends the document. The default is ``Kind/query``.
    public init(query: String, variables: [String: Map] = [:], from: String, to: String, kind: Kind = .query) {
        self.query = query
        self.variables = variables
        self.from = from
        self.to = to
        self.kind = kind
    }
}

/// The conformance check of a ``GraphQLEndpoint``: the facts that a host and a client read, the response conventions
/// of the toolkit, the forgiving names, and the rules of the endpoint conventions (EXTRAS-9) that a machine can check
/// from the SDL and the facts, which ``GraphQLConventionRule`` lists.
public enum GraphQLEndpointConformance {
    /// A document that does not parse.
    private static let brokenDocument = "{"

    /// A query that each schema answers.
    private static let typenameQuery = "{ __typename }"

    /// The number of seconds in ``firstResponseLimit``.
    private static let firstResponseLimitSeconds = 10

    /// The longest time that the check waits for the first response of a subscription. A subscription that sends no
    /// response in this time is a problem, so the check does not hang on an endpoint that never sends.
    public static let firstResponseLimit: Duration = .seconds(firstResponseLimitSeconds)

    /// What a subscription gives first.
    private enum FirstResponse: Sendable {
        /// The JSON text of the first response.
        case response(String)

        /// The stream ended with no response.
        case ended

        /// No response came in ``GraphQLEndpointConformance/firstResponseLimit``.
        case timedOut
    }

    /// Checks an endpoint with one alias probe.
    ///
    /// This is ``problems(of:scope:probes:codes:exceptions:clock:)`` with a list of one probe and the real time.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - scope: The scope that the endpoint must have.
    ///   - probe: A call with an alias name.
    ///   - codes: Each error code and warning code that the endpoint can give, for rule 8. The default is none.
    ///   - exceptions: The rules that the endpoint does not obey yet, each with the task that removes it. The default
    ///     is none.
    /// - Returns: The problems, or an empty list when the endpoint conforms.
    public static func problems(
        of endpoint: any GraphQLEndpoint,
        scope: GraphQLEndpointScope,
        probe: GraphQLAliasProbe,
        codes: [String] = [],
        exceptions: [GraphQLConventionException] = []
    ) async -> [String] {
        await problems(of: endpoint, scope: scope, probes: [probe], codes: codes, exceptions: exceptions)
    }

    /// Checks an endpoint.
    ///
    /// The check reads the name, the version, and the SDL schema, then sends these calls with no viewer:
    ///
    /// - `{ __typename }` must give `data.__typename` and no error;
    /// - a document that does not parse must give one error with the code `GRAPHQL_PARSE_FAILED`, also from
    ///   `subscribe`;
    /// - each alias probe must give `data`, no error, and the rewrite of the probe in `extensions.rewrites`. A
    ///   ``GraphQLAliasProbe/Kind/subscription`` probe goes through `subscribe`, and the check reads its first
    ///   response.
    ///
    /// The check waits at most ``firstResponseLimit`` for the first response of a subscription, and a subscription
    /// that sends none in that time, or that ends with none, is a problem.
    ///
    /// It then checks each rule of ``GraphQLConventionRule`` that has no exception, and each problem of a rule starts
    /// with the name of the rule, for example `rule 9: …`. The codes of rule 8 are not in the SDL, and one call does
    /// not give them all, so the endpoint gives its codes: each code of its own `CodedError` types and each warning
    /// code that it can give.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - scope: The scope that the endpoint must have.
    ///   - probes: The calls with an alias name, for example one query alias and one subscription alias.
    ///   - codes: Each error code and warning code that the endpoint can give, for rule 8. The default is none.
    ///   - exceptions: The rules that the endpoint does not obey yet, each with the task that removes it. The default
    ///     is none.
    ///   - clock: The clock of the wait for the first response of a subscription. The default is the real time; a
    ///     test gives a ``ManualRunClock``.
    /// - Returns: The problems, or an empty list when the endpoint conforms.
    public static func problems(
        of endpoint: any GraphQLEndpoint,
        scope: GraphQLEndpointScope,
        probes: [GraphQLAliasProbe],
        codes: [String] = [],
        exceptions: [GraphQLConventionException] = [],
        clock: any RunClock = ContinuousRunClock()
    ) async -> [String] {
        var problems = facts(of: endpoint, scope: scope)
        problems += GraphQLConventions.problems(of: endpoint, codes: codes, exceptions: exceptions)
        problems += await check("The call \(typenameQuery)") {
            let response = try await execute(typenameQuery, on: endpoint)
            return errorsAndData(of: response, needsData: true)
                + ((response.data?["__typename"] as? String) == nil ? ["gave no data.__typename"] : [])
        }
        problems += await check("A document that does not parse") {
            parseFailureProblems(of: try await execute(brokenDocument, on: endpoint))
        }
        problems += await check("A subscription document that does not parse") {
            let stream = try await subscribe(brokenDocument, on: endpoint)
            return try await firstResponseProblems(of: stream, clock: clock, parseFailureProblems)
        }
        for probe in probes {
            problems += await aliasProblems(of: probe, on: endpoint, clock: clock)
        }
        return problems
    }

    /// Sends one alias probe the way its kind asks, and gives its problems.
    ///
    /// - Parameters:
    ///   - probe: The probe.
    ///   - endpoint: The endpoint.
    ///   - clock: The clock of the wait for the first response of a subscription.
    /// - Returns: The problems of the probe, each with the probe in its subject.
    private static func aliasProblems(
        of probe: GraphQLAliasProbe,
        on endpoint: any GraphQLEndpoint,
        clock: any RunClock
    ) async -> [String] {
        switch probe.kind {
        case .query:
            await check("The alias probe \(probe.query)") {
                let response = try await execute(probe.query, variables: probe.variables, on: endpoint)
                return rewriteProblems(of: response, probe: probe)
            }
        case .subscription:
            await check("The subscription alias probe \(probe.query)") {
                let stream = try await subscribe(probe.query, variables: probe.variables, on: endpoint)
                return try await firstResponseProblems(of: stream, clock: clock) { response in
                    rewriteProblems(of: response, probe: probe)
                }
            }
        }
    }

    /// Gives the problems of the response to an alias probe: an error, no `data`, or no rewrite of the probe in
    /// `extensions.rewrites`.
    ///
    /// - Parameters:
    ///   - response: The response.
    ///   - probe: The probe.
    /// - Returns: The problems.
    private static func rewriteProblems(of response: ParsedResponse, probe: GraphQLAliasProbe) -> [String] {
        let rewrites = response.extensions?["rewrites"] as? [[String: Any]] ?? []
        let reported = rewrites.contains { rewrite in
            rewrite["from"] as? String == probe.from && rewrite["to"] as? String == probe.to
        }
        return errorsAndData(of: response, needsData: true)
            + (reported ? [] : ["gave no rewrite from \(probe.from) to \(probe.to) in extensions.rewrites"])
    }

    /// Reads the first response of a subscription, and gives its problems.
    ///
    /// - Parameters:
    ///   - stream: The stream of the subscription.
    ///   - clock: The clock of the wait.
    ///   - responseProblems: Gives the problems of the first response.
    /// - Returns: The problems of the first response, or one problem when the stream ends with no response or sends
    ///   none in ``firstResponseLimit``.
    /// - Throws: The error that ends the stream, or ``ParsedResponse/NotAnObject`` when the response is not a JSON
    ///   object.
    private static func firstResponseProblems(
        of stream: AsyncThrowingStream<String, Error>,
        clock: any RunClock,
        _ responseProblems: (ParsedResponse) -> [String]
    ) async throws -> [String] {
        switch try await firstResponse(of: stream, clock: clock) {
        case .response(let json):
            responseProblems(try ParsedResponse(json: json))
        case .ended:
            ["gave no response"]
        case .timedOut:
            ["gave no response within \(firstResponseLimit)"]
        }
    }

    /// Waits for the first response of a subscription, at most ``firstResponseLimit``.
    ///
    /// The read of the stream races a sleep on `clock`, and the loser is cancelled, so a stream that stays open with
    /// no response does not hang the check.
    ///
    /// - Parameters:
    ///   - stream: The stream of the subscription.
    ///   - clock: The clock of the wait.
    /// - Returns: What the subscription gave first.
    /// - Throws: The error that ends the stream.
    private static func firstResponse(
        of stream: AsyncThrowingStream<String, Error>,
        clock: any RunClock
    ) async throws -> FirstResponse {
        let deadline = clock.now.advanced(by: firstResponseLimit)
        return try await withThrowingTaskGroup(of: FirstResponse.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return try await iterator.next().map(FirstResponse.response) ?? .ended
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                return .timedOut
            }
            defer { group.cancelAll() }
            // The group holds two tasks, so its first result is never `nil`.
            return try await group.next() ?? .timedOut
        }
    }

    /// Checks the name, the version, the scope, and the SDL of an endpoint.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - scope: The scope that the endpoint must have.
    /// - Returns: The problems.
    private static func facts(of endpoint: any GraphQLEndpoint, scope: GraphQLEndpointScope) -> [String] {
        var problems: [String] = []
        if endpoint.name.isEmpty || endpoint.name.contains(where: \.isWhitespace) {
            problems.append("The name \"\(endpoint.name)\" is empty or has white space.")
        }
        if endpoint.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("The version is empty.")
        }
        if endpoint.scope != scope {
            problems.append("The scope is \(endpoint.scope.rawValue), not \(scope.rawValue).")
        }
        do {
            let schema = try buildSchema(source: endpoint.schema)
            if schema.queryType == nil {
                problems.append("The SDL schema has no query type.")
            }
        } catch {
            problems.append("The SDL schema does not build: \(error).")
        }
        return problems
    }

    /// Runs one check, and gives its problems with a subject, or the error that the check threw.
    ///
    /// - Parameters:
    ///   - subject: The subject of each problem.
    ///   - body: The check.
    /// - Returns: The problems of the check.
    private static func check(_ subject: String, _ body: () async throws -> [String]) async -> [String] {
        do {
            return try await body().map { problem in "\(subject) \(problem)." }
        } catch {
            return ["\(subject) threw \(error)."]
        }
    }

    /// Runs one document with no viewer.
    ///
    /// - Parameters:
    ///   - query: The document.
    ///   - variables: The values of the variables.
    ///   - endpoint: The endpoint.
    /// - Returns: The parsed response.
    /// - Throws: The error of the endpoint, or ``ParsedResponse/NotAnObject`` when the response is not a JSON object.
    private static func execute(
        _ query: String,
        variables: [String: Map] = [:],
        on endpoint: any GraphQLEndpoint
    ) async throws -> ParsedResponse {
        try ParsedResponse(
            json: await endpoint.execute(query: query, variables: variables, operationName: nil, viewer: nil)
        )
    }

    /// Starts one subscription document with no viewer.
    ///
    /// - Parameters:
    ///   - query: The document.
    ///   - variables: The values of the variables.
    ///   - endpoint: The endpoint.
    /// - Returns: The stream of the responses.
    /// - Throws: The error of the endpoint.
    private static func subscribe(
        _ query: String,
        variables: [String: Map] = [:],
        on endpoint: any GraphQLEndpoint
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await endpoint.subscribe(query: query, variables: variables, operationName: nil, viewer: nil)
    }

    /// Gives the problems of a response that must have no error, and `data` when the caller asks for it.
    ///
    /// - Parameters:
    ///   - response: The response.
    ///   - needsData: `true` when the response must have `data`.
    /// - Returns: The problems.
    private static func errorsAndData(of response: ParsedResponse, needsData: Bool) -> [String] {
        let errors = response.errors.map { error in error["message"] as? String ?? "\(error)" }
        let errorProblems = errors.isEmpty ? [] : ["gave the errors \(errors)"]
        return errorProblems + (needsData && response.data == nil ? ["gave no data"] : [])
    }

    /// Gives the problems of the response of a document that does not parse.
    ///
    /// - Parameter response: The response.
    /// - Returns: No problem when the response has one error with the code `GRAPHQL_PARSE_FAILED`.
    private static func parseFailureProblems(of response: ParsedResponse) -> [String] {
        let codes = response.errors.compactMap { error in (error["extensions"] as? [String: Any])?["code"] as? String }
        let expected = GraphQLToolkitError.graphQLParseFailed(detail: "").code
        return codes == [expected] ? [] : ["gave the codes \(codes), not [\(expected)]"]
    }
}

/// A GraphQL response that the conformance check reads.
private struct ParsedResponse {
    /// The error of a response that is not a JSON object.
    struct NotAnObject: Error, CustomStringConvertible {
        /// The text of the response.
        let json: String

        /// The text of the error.
        var description: String {
            "the response is not a JSON object: \(json)"
        }
    }

    /// The `data` object, or `nil` when the response has none.
    let data: [String: Any]?

    /// The `errors` list.
    let errors: [[String: Any]]

    /// The `extensions` object, or `nil` when the response has none.
    let extensions: [String: Any]?

    /// Reads a response.
    ///
    /// - Parameter json: The JSON text of the response.
    /// - Throws: ``NotAnObject`` when the text is not a JSON object.
    init(json: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NotAnObject(json: json)
        }
        data = object["data"] as? [String: Any]
        errors = object["errors"] as? [[String: Any]] ?? []
        extensions = object["extensions"] as? [String: Any]
    }
}
