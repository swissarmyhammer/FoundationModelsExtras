import Foundation
import GraphQL

/// A rule of the endpoint conventions (EXTRAS-9) that ``GraphQLEndpointConformance`` checks from the SDL schema and
/// the facts of an endpoint. The raw value is the number of the rule in EXTRAS-9.
public enum GraphQLConventionRule: Int, CaseIterable, Hashable, Sendable {
    /// Rule 3: an endpoint that the rule names has the scope of the rule: `server` for `sessions`, `settings` and
    /// `snapshots`, and `sessionFolder` for `kanban`, `files`, `rules`, `agents` and `skills`.
    case scope = 3

    /// Rule 7: each mutation has the form `verbNoun(input: VerbNounInput!)`. An endpoint with no `Mutation` type
    /// obeys it.
    case mutations = 7

    /// Rule 8: each code of the endpoint is `UPPER_SNAKE`.
    case codes = 8

    /// Rule 9: the subscription `changes(after: String)`, whose event has `cursor: String!`, `at: DateTime!`,
    /// `added: [ID!]!`, `changed: [ID!]!` and `removed: [ID!]!`, and the root query `cursor: String!`. Each other
    /// argument of `changes` and `cursor` is optional.
    case changes = 9

    /// The name that each problem of the rule starts with, for example `rule 9`.
    public var name: String {
        "rule \(rawValue)"
    }
}

/// A rule that an endpoint cannot obey yet, with the task that removes the exception.
///
/// The conformance check does not report the problems of an excepted rule. An exception that names no task is a
/// problem, so that each exception has a known end.
public struct GraphQLConventionException: Hashable, Sendable {
    /// The rule that the endpoint does not obey yet.
    public var rule: GraphQLConventionRule

    /// The id of the task that removes the exception, for example `KANBAN-7`.
    public var removedBy: String

    /// Makes an exception.
    ///
    /// - Parameters:
    ///   - rule: The rule that the endpoint does not obey yet.
    ///   - removedBy: The id of the task that removes the exception.
    public init(rule: GraphQLConventionRule, removedBy: String) {
        self.rule = rule
        self.removedBy = removedBy
    }
}

/// The checks of the rules of ``GraphQLConventionRule``: each gives the problems of one rule, with no rule name.
enum GraphQLConventions {
    /// The scope of each endpoint that rule 3 names.
    static let scopes: [String: GraphQLEndpointScope] = [
        "sessions": .server,
        "settings": .server,
        "snapshots": .server,
        "kanban": .sessionFolder,
        "files": .sessionFolder,
        "rules": .sessionFolder,
        "agents": .sessionFolder,
        "skills": .sessionFolder,
    ]

    /// The name of the subscription of rule 9.
    static let changesField = "changes"

    /// The argument of `changes` that takes the cursor to resume after.
    static let afterArgument = "after"

    /// The SDL type of the argument `after`.
    static let afterType = "String"

    /// The name of the root query of rule 9.
    static let cursorField = "cursor"

    /// The SDL type of the root query `cursor`.
    static let cursorType = "String!"

    /// The fields that the event of `changes` must have, with their SDL types, in the order of rule 9.
    static let eventFields = [
        (name: "cursor", type: "String!"),
        (name: "at", type: "DateTime!"),
        (name: "added", type: "[ID!]!"),
        (name: "changed", type: "[ID!]!"),
        (name: "removed", type: "[ID!]!"),
    ]

    /// The one argument of a mutation of rule 7.
    static let inputArgument = "input"

    /// The end of the name of the `input` type of a mutation of rule 7.
    static let inputSuffix = "Input"

    /// The form of rule 7, for a mutation whose name is not `verbNoun`.
    static let mutationForm = "verbNoun(input: VerbNounInput!)"

    /// Checks the rules of ``GraphQLConventionRule`` that have no exception.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - codes: The codes of the endpoint, for rule 8.
    ///   - exceptions: The rules that the endpoint does not obey yet.
    /// - Returns: Each problem of an exception that names no task, then each problem of a rule with no exception,
    ///   each with the name of its rule, for example `rule 9: …`.
    static func problems(
        of endpoint: any GraphQLEndpoint,
        codes: [String],
        exceptions: [GraphQLConventionException]
    ) -> [String] {
        // An SDL that does not build is a problem of the facts of the endpoint, so the rules that read it pass.
        let schema = try? buildSchema(source: endpoint.schema)
        let excepted = Set(exceptions.map(\.rule))
        let ruleProblems = GraphQLConventionRule.allCases.flatMap { rule in
            excepted.contains(rule)
                ? []
                : problems(of: rule, endpoint: endpoint, schema: schema, codes: codes).map { problem in
                    "\(rule.name): \(problem)"
                }
        }
        return exceptionProblems(exceptions) + ruleProblems
    }

    /// Gives the problems of the exceptions that name no task.
    ///
    /// - Parameter exceptions: The exceptions.
    /// - Returns: One problem for each exception whose task id is empty or white space.
    static func exceptionProblems(_ exceptions: [GraphQLConventionException]) -> [String] {
        exceptions
            .filter { exception in exception.removedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { exception in "The exception of \(exception.rule.name) names no task that removes it." }
    }

    /// Checks one rule.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - endpoint: The endpoint.
    ///   - schema: The schema built from the SDL of the endpoint, or `nil` when it does not build.
    ///   - codes: The codes of the endpoint.
    /// - Returns: The problems of the rule.
    static func problems(
        of rule: GraphQLConventionRule,
        endpoint: any GraphQLEndpoint,
        schema: GraphQLSchema?,
        codes: [String]
    ) -> [String] {
        switch rule {
        case .scope: scopeProblems(of: endpoint)
        case .mutations: schemaProblems(of: schema, check: mutationProblems(in:))
        case .codes: codeProblems(of: codes)
        case .changes: schemaProblems(of: schema, check: changesProblems(in:))
        }
    }

    /// Runs a check of the schema, and gives a fault of the schema as a problem.
    ///
    /// - Parameters:
    ///   - schema: The schema, or `nil` when the SDL does not build.
    ///   - check: The check.
    /// - Returns: The problems of the check, none when there is no schema, or one problem when the schema throws.
    static func schemaProblems(
        of schema: GraphQLSchema?,
        check: (GraphQLSchema) throws -> [String]
    ) -> [String] {
        guard let schema else {
            return []
        }
        do {
            return try check(schema)
        } catch {
            return ["The SDL schema cannot be read: \(error)."]
        }
    }

    /// Checks rule 3.
    ///
    /// - Parameter endpoint: The endpoint.
    /// - Returns: One problem when rule 3 names the endpoint with another scope.
    static func scopeProblems(of endpoint: any GraphQLEndpoint) -> [String] {
        guard let expected = scopes[endpoint.name], expected != endpoint.scope else {
            return []
        }
        return [
            "The endpoint \(endpoint.name) must have the scope \(expected.rawValue), not \(endpoint.scope.rawValue)."
        ]
    }

    /// Checks rule 7.
    ///
    /// - Parameter schema: The schema.
    /// - Returns: One problem for each mutation that is not of the form `verbNoun(input: VerbNounInput!)`.
    /// - Throws: An error from the schema when the `Mutation` type gives no fields.
    static func mutationProblems(in schema: GraphQLSchema) throws -> [String] {
        guard let mutation = schema.mutationType else {
            return []
        }
        return try mutation.fields().compactMap { name, field in
            let found = signature(of: field, named: name)
            let expected = expectedSignature(ofMutation: name)
            return found == expected ? nil : "The mutation \(found) is not of the form \(expected)."
        }
    }

    /// Gives the signature of a field as SDL, for example `addNote(input: AddNoteInput!)`.
    ///
    /// - Parameters:
    ///   - field: The field.
    ///   - name: The name of the field.
    /// - Returns: The name and the arguments with their types.
    static func signature(of field: GraphQLField, named name: String) -> String {
        let arguments = field.args.map { argument, definition in "\(argument): \(definition.type.debugDescription)" }
        return "\(name)(\(arguments.joined(separator: ", ")))"
    }

    /// Gives the signature that rule 7 asks of a mutation.
    ///
    /// - Parameter name: The name of the mutation.
    /// - Returns: `name(input: NameInput!)` when the name is `verbNoun`, else the general form of rule 7.
    static func expectedSignature(ofMutation name: String) -> String {
        guard name.wholeMatch(of: #/[a-z]+[A-Z][A-Za-z0-9]*/#) != nil else {
            return mutationForm
        }
        return "\(name)(\(inputArgument): \(name.prefix(1).uppercased())\(name.dropFirst())\(inputSuffix)!)"
    }

    /// Checks rule 8.
    ///
    /// - Parameter codes: The codes of the endpoint.
    /// - Returns: One problem for each code that is not `UPPER_SNAKE`.
    static func codeProblems(of codes: [String]) -> [String] {
        codes
            .filter { code in code.wholeMatch(of: #/[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*/#) == nil }
            .map { code in "The code \(code) is not UPPER_SNAKE." }
    }

    /// Checks rule 9.
    ///
    /// - Parameter schema: The schema.
    /// - Returns: The problems of the subscription `changes` and of the root query `cursor`.
    /// - Throws: An error from the schema when a type gives no fields.
    static func changesProblems(in schema: GraphQLSchema) throws -> [String] {
        try subscriptionProblems(in: schema) + cursorProblems(in: schema)
    }

    /// Checks the subscription `changes` of rule 9.
    ///
    /// - Parameter schema: The schema.
    /// - Returns: The problems of the subscription, its arguments, and its event.
    /// - Throws: An error from the schema when a type gives no fields.
    static func subscriptionProblems(in schema: GraphQLSchema) throws -> [String] {
        guard let changes = try schema.subscriptionType?.fields()[changesField] else {
            return ["The schema has no subscription \(changesField)(\(afterArgument): \(afterType))."]
        }
        let after = changes.args[afterArgument]?.type.debugDescription
        let afterProblems =
            after == afterType
            ? [] : ["The subscription \(changesField) has no argument \(afterArgument): \(afterType)."]
        return afterProblems
            + requiredArgumentProblems(of: changes, named: changesField, except: afterArgument)
            + (try eventProblems(of: changes.type))
    }

    /// Checks the event of the subscription `changes` of rule 9.
    ///
    /// - Parameter type: The type that `changes` gives.
    /// - Returns: One problem for each field of rule 9 that the event does not have with its type.
    /// - Throws: An error from the schema when the event gives no fields.
    static func eventProblems(of type: any GraphQLOutputType) throws -> [String] {
        guard let event = getNamedType(type: type) as? GraphQLObjectType else {
            return ["The subscription \(changesField) gives \(type.debugDescription), not an object type."]
        }
        let fields = try event.fields()
        return eventFields.compactMap { name, expected in
            fields[name]?.type.debugDescription == expected
                ? nil : "The event \(event.name) of \(changesField) has no field \(name): \(expected)."
        }
    }

    /// Checks the root query `cursor` of rule 9.
    ///
    /// - Parameter schema: The schema.
    /// - Returns: The problems of the query and its arguments.
    /// - Throws: An error from the schema when the query type gives no fields.
    static func cursorProblems(in schema: GraphQLSchema) throws -> [String] {
        guard let cursor = try schema.queryType?.fields()[cursorField],
            cursor.type.debugDescription == cursorType
        else {
            return ["The schema has no query \(cursorField): \(cursorType)."]
        }
        return requiredArgumentProblems(of: cursor, named: cursorField, except: nil)
    }

    /// Gives a problem for each argument of a field that is required, because rule 9 asks that each more argument
    /// of `changes` and `cursor` is optional.
    ///
    /// - Parameters:
    ///   - field: The field.
    ///   - name: The name of the field.
    ///   - kept: The argument that rule 9 checks on its own, or `nil` for none.
    /// - Returns: One problem for each other argument whose type is non-null.
    static func requiredArgumentProblems(of field: GraphQLField, named name: String, except kept: String?) -> [String] {
        field.args.compactMap { argument, definition in
            argument != kept && definition.type is GraphQLNonNull
                ? "The argument \(name)(\(argument):) is required; each more argument of \(name) must be optional."
                : nil
        }
    }
}
