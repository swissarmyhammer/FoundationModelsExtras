import Foundation
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// An endpoint that has only an SDL schema, for the convention checks that read the SDL: each call gives
/// `__typename`, and each subscription ends at once.
struct SDLEndpoint: GraphQLEndpoint {
    let name: String
    let version = "1"
    let scope: GraphQLEndpointScope
    let schema: String

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
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

/// One SDL that breaks one rule, and the rule that it breaks.
struct RuleBreak: Sendable, CustomTestStringConvertible {
    /// What the SDL breaks.
    let label: String

    /// The rule that the SDL breaks.
    let rule: GraphQLConventionRule

    /// The SDL.
    let schema: String

    var testDescription: String { label }
}

/// Proves the checks of the EXTRAS-9 conventions in ``GraphQLEndpointConformance``.
@Suite("GraphQL endpoint conventions")
struct GraphQLConventionTests {
    /// The parts of an SDL that obey each rule, and that each break replaces one at a time.
    enum Part {
        /// The scalars and the types that no rule reads.
        static let base = """
            scalar DateTime
            type Note { id: ID! }
            input AddNoteInput { title: String! }
            """

        /// A root query with `cursor` and an optional filter.
        static let query = "type Query { cursor(board: ID): String! note(id: ID!): Note }"

        /// A mutation of the form `verbNoun(input: VerbNounInput!)`.
        static let mutation = "type Mutation { addNote(input: AddNoteInput!): Note }"

        /// The event of `changes`.
        static let event = """
            type NoteChange { cursor: String! at: DateTime! added: [ID!]! changed: [ID!]! removed: [ID!]! }
            """

        /// The `changes` subscription with an optional filter.
        static let subscription = "type Subscription { changes(after: String, filter: String): NoteChange! }"
    }

    /// The name of the endpoint of the fixtures, which rule 3 gives the scope `sessionFolder`.
    static let name = "kanban"

    /// The codes of the endpoint of the fixtures, each in `UPPER_SNAKE`.
    static let codes = ["NOT_FOUND", "INCOMPATIBLE_BOARD", "RESYNC_REQUIRED"]

    /// The task that removes the exception of the fixtures.
    static let removingTask = "KANBAN-7"

    /// Builds an SDL from the parts.
    ///
    /// - Parameters:
    ///   - query: The root query.
    ///   - mutation: The mutation type, or an empty text for none.
    ///   - event: The event of `changes`.
    ///   - subscription: The subscription type, or an empty text for none.
    /// - Returns: The SDL.
    static func sdl(
        query: String = Part.query,
        mutation: String = Part.mutation,
        event: String = Part.event,
        subscription: String = Part.subscription
    ) -> String {
        [Part.base, query, mutation, event, subscription].joined(separator: "\n")
    }

    /// The SDLs that each break one rule.
    static let breaks: [RuleBreak] = [
        RuleBreak(label: "no subscription", rule: .changes, schema: sdl(subscription: "")),
        RuleBreak(
            label: "no changes",
            rule: .changes,
            schema: sdl(subscription: "type Subscription { noteChanges(after: String): NoteChange! }")
        ),
        RuleBreak(
            label: "changes with no after",
            rule: .changes,
            schema: sdl(subscription: "type Subscription { changes: NoteChange! }")
        ),
        RuleBreak(
            label: "after that is required",
            rule: .changes,
            schema: sdl(subscription: "type Subscription { changes(after: String!): NoteChange! }")
        ),
        RuleBreak(
            label: "changes with a required filter",
            rule: .changes,
            schema: sdl(subscription: "type Subscription { changes(after: String, board: ID!): NoteChange! }")
        ),
        RuleBreak(
            label: "an event with no removed",
            rule: .changes,
            schema: sdl(event: "type NoteChange { cursor: String! at: DateTime! added: [ID!]! changed: [ID!]! }")
        ),
        RuleBreak(
            label: "an event whose at is a String",
            rule: .changes,
            schema: sdl(
                event: "type NoteChange { cursor: String! at: String! added: [ID!]! changed: [ID!]! removed: [ID!]! }"
            )
        ),
        RuleBreak(
            label: "no cursor",
            rule: .changes,
            schema: sdl(query: "type Query { note(id: ID!): Note }")
        ),
        RuleBreak(
            label: "a cursor that can be null",
            rule: .changes,
            schema: sdl(query: "type Query { cursor: String note(id: ID!): Note }")
        ),
        RuleBreak(
            label: "a cursor with a required argument",
            rule: .changes,
            schema: sdl(query: "type Query { cursor(board: ID!): String! note(id: ID!): Note }")
        ),
        RuleBreak(
            label: "a mutation with no input",
            rule: .mutations,
            schema: sdl(mutation: "type Mutation { deleteNote(id: ID!): Note }")
        ),
        RuleBreak(
            label: "an input with another type name",
            rule: .mutations,
            schema: sdl(mutation: "type Mutation { addNote(input: NoteInput!): Note } input NoteInput { a: Int }")
        ),
        RuleBreak(
            label: "an input that can be null",
            rule: .mutations,
            schema: sdl(mutation: "type Mutation { addNote(input: AddNoteInput): Note }")
        ),
        RuleBreak(
            label: "a mutation with a bare verb",
            rule: .mutations,
            schema: sdl(mutation: "type Mutation { add(input: AddInput!): Note } input AddInput { a: Int }")
        ),
        RuleBreak(
            label: "a mutation with one more argument",
            rule: .mutations,
            schema: sdl(mutation: "type Mutation { addNote(input: AddNoteInput!, force: Boolean): Note }")
        ),
    ]

    /// Checks an endpoint of the fixtures.
    ///
    /// - Parameters:
    ///   - schema: The SDL.
    ///   - name: The name of the endpoint.
    ///   - scope: The scope of the endpoint.
    ///   - codes: The codes of the endpoint.
    ///   - exceptions: The rule exceptions.
    /// - Returns: The problems that name a rule.
    static func ruleProblems(
        of schema: String,
        name: String = name,
        scope: GraphQLEndpointScope = .sessionFolder,
        codes: [String] = codes,
        exceptions: [GraphQLConventionException] = []
    ) async -> [String] {
        let problems = await GraphQLEndpointConformance.problems(
            of: SDLEndpoint(name: name, scope: scope, schema: schema),
            scope: scope,
            probe: GraphQLAliasProbe(query: "{ __typename }", from: "a", to: "a"),
            codes: codes,
            exceptions: exceptions
        )
        return problems.filter { problem in problem.hasPrefix("rule ") }
    }

    /// Gives the problems of one rule.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - problems: The problems.
    /// - Returns: The problems that name the rule.
    static func problems(of rule: GraphQLConventionRule, in problems: [String]) -> [String] {
        problems.filter { problem in problem.hasPrefix("\(rule.name):") }
    }

    @Test("an SDL that obeys each rule has no rule problem")
    func conformingSDLHasNoRuleProblem() async {
        #expect(await Self.ruleProblems(of: Self.sdl()) == [])
    }

    @Test("each SDL that breaks a rule gives a problem that names that rule", arguments: breaks)
    func ruleBreakNamesItsRule(_ ruleBreak: RuleBreak) async {
        let problems = await Self.ruleProblems(of: ruleBreak.schema)

        #expect(!problems.isEmpty)
        #expect(Self.problems(of: ruleBreak.rule, in: problems) == problems)
    }

    @Test("an endpoint with no Mutation type passes rule 7")
    func noMutationPassesRuleSeven() async {
        #expect(await Self.ruleProblems(of: Self.sdl(mutation: "")) == [])
    }

    @Test("a code that is not UPPER_SNAKE breaks rule 8")
    func codeThatIsNotUpperSnakeBreaksRuleEight() async {
        let problems = await Self.ruleProblems(of: Self.sdl(), codes: ["NOT_FOUND", "notFound", "BAD__CODE", "_X"])

        #expect(
            problems == [
                "rule 8: The code notFound is not UPPER_SNAKE.",
                "rule 8: The code BAD__CODE is not UPPER_SNAKE.",
                "rule 8: The code _X is not UPPER_SNAKE.",
            ]
        )
    }

    @Test("an endpoint of rule 3 with the other scope breaks rule 3")
    func scopeThatDisagreesBreaksRuleThree() async {
        let sessions = await Self.ruleProblems(of: Self.sdl(), name: "sessions", scope: .sessionFolder)
        let kanban = await Self.ruleProblems(of: Self.sdl(), name: "kanban", scope: .server)

        #expect(sessions == ["rule 3: The endpoint sessions must have the scope server, not sessionFolder."])
        #expect(kanban == ["rule 3: The endpoint kanban must have the scope sessionFolder, not server."])
    }

    @Test("an endpoint that rule 3 does not name passes rule 3 with each scope")
    func unnamedEndpointPassesRuleThree() async {
        for scope in GraphQLEndpointScope.allCases {
            #expect(await Self.ruleProblems(of: Self.sdl(), name: "notes", scope: scope) == [])
        }
    }

    @Test("an exception removes the problems of its rule, and only those")
    func exceptionRemovesOnlyItsRule() async {
        let schema = Self.sdl(mutation: "type Mutation { deleteNote(id: ID!): Note }", subscription: "")
        let exception = GraphQLConventionException(rule: .changes, removedBy: Self.removingTask)

        let all = await Self.ruleProblems(of: schema)
        let excepted = await Self.ruleProblems(of: schema, exceptions: [exception])

        #expect(!Self.problems(of: .changes, in: all).isEmpty)
        #expect(excepted == Self.problems(of: .mutations, in: all))
        #expect(!excepted.isEmpty)
    }

    @Test("an exception that names no task is a problem")
    func exceptionWithNoTaskIsAProblem() async {
        let exception = GraphQLConventionException(rule: .changes, removedBy: " ")

        let problems = await GraphQLEndpointConformance.problems(
            of: SDLEndpoint(name: Self.name, scope: .sessionFolder, schema: Self.sdl()),
            scope: .sessionFolder,
            probe: GraphQLAliasProbe(query: "{ __typename }", from: "a", to: "a"),
            exceptions: [exception]
        )

        #expect(problems.contains("The exception of rule 9 names no task that removes it."))
    }

    @Test("the name of each rule is its number in EXTRAS-9")
    func ruleNames() {
        #expect(GraphQLConventionRule.allCases.map(\.name) == ["rule 3", "rule 7", "rule 8", "rule 9"])
    }
}
