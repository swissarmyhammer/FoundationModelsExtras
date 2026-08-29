import FoundationModels
import Testing

@testable import Operations

/// Shared `Context` for every `OperationTool` fixture operation below.
/// Dispatch correctness is verified through each operation's JSON output,
/// so the context itself carries no mutable state.
private struct ToolFixtureContext: Sendable {}

/// JSON-encodable result produced by `AddNoteToolFixture.execute(in:)`.
private struct AddNoteOutput: Encodable, Sendable, Equatable {
    let title: String
    let tags: [String]
    let authorName: String?
}

/// `add note` fixture: a required `title` (aliased `name`), an optional
/// `tags` array (aliased `labels`), and an optional `authorName` — the last
/// exercising camelCase/snake_case key normalization (no declared alias).
private struct AddNoteToolFixture: OperationDefinition {
    typealias Context = ToolFixtureContext
    typealias Output = AddNoteOutput

    var title: String
    var tags: [String]
    var authorName: String?

    static let verb = "add"
    static let noun = "note"
    static let operationDescription = "Create a new note"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "title", type: .string, required: true, description: "The note title", aliases: ["name"]),
        ParamMeta(name: "tags", type: .array(of: .string), required: false, description: "Tags to attach", aliases: ["labels"]),
        ParamMeta(name: "authorName", type: .string, required: false, description: "The note's author"),
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: AddNoteToolFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        title = try content.value(String.self, forProperty: "title")
        tags = (try? content.value([String].self, forProperty: "tags")) ?? []
        authorName = try content.value(String?.self, forProperty: "authorName")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["title": title, "tags": tags])
    }

    func execute(in context: ToolFixtureContext) async throws -> AddNoteOutput {
        AddNoteOutput(title: title, tags: tags, authorName: authorName)
    }
}

/// JSON-encodable result produced by `DeleteNoteToolFixture.execute(in:)`.
private struct DeleteNoteOutput: Encodable, Sendable, Equatable {
    let id: String
}

/// `delete note` fixture: a single required `id`, giving the resolver a
/// second op to disambiguate against and to list on an unknown-op failure.
private struct DeleteNoteToolFixture: OperationDefinition {
    typealias Context = ToolFixtureContext
    typealias Output = DeleteNoteOutput

    var id: String

    static let verb = "delete"
    static let noun = "note"
    static let operationDescription = "Delete a note by id"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The note id")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: DeleteNoteToolFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        id = try content.value(String.self, forProperty: "id")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["id": id])
    }

    func execute(in context: ToolFixtureContext) async throws -> DeleteNoteOutput {
        DeleteNoteOutput(id: id)
    }
}

/// JSON-encodable result produced by `DecodingFailureToolFixture.execute(in:)`.
/// Never actually reached — `init(_:)` always throws first — but required to
/// satisfy `OperationDefinition.Output`.
private struct DecodingFailureOutput: Encodable, Sendable, Equatable {
    let title: String
}

/// Thrown unconditionally by `DecodingFailureToolFixture.init(_:)`, standing
/// in for a real decode failure (e.g. a value that fails a `Generable`
/// type's own validation).
private struct FixtureDecodingError: Error {}

/// `fail decode` fixture: a required `title` the resolver can always find
/// (so `resolveParameters` reports no missing parameters), but whose
/// `init(_:)` unconditionally throws — exercising `AnyOperation.run`'s
/// `OperationError.decodingFailed` path independent of parameter presence.
private struct DecodingFailureToolFixture: OperationDefinition, Sendable {
    typealias Context = ToolFixtureContext
    typealias Output = DecodingFailureOutput

    var title: String

    static let verb = "fail"
    static let noun = "decode"
    static let operationDescription = "Always fails to decode its resolved payload"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "title", type: .string, required: true, description: "Present but never read")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: DecodingFailureToolFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        throw FixtureDecodingError()
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["title": title])
    }

    func execute(in context: ToolFixtureContext) async throws -> DecodingFailureOutput {
        DecodingFailureOutput(title: title)
    }
}

@Suite struct OperationToolTests {

    private func makeTool(
        resolver: OperationResolver = OperationResolver(),
        retryCap: Int = 2
    ) throws -> OperationTool<ToolFixtureContext> {
        try OperationTool(
            name: "notes",
            description: "Note operations",
            context: ToolFixtureContext(),
            operations: [
                AnyOperation(AddNoteToolFixture.self),
                AnyOperation(DeleteNoteToolFixture.self),
            ],
            resolver: resolver,
            retryCap: retryCap
        )
    }

    // MARK: - Operations exposure (CLI driver assembly)

    @Test func operationsExposesEveryRegisteredOperationInOrder() throws {
        let tool = try makeTool()

        #expect(tool.operations.map(\.opString) == ["add note", "delete note"])
    }

    // MARK: - Tool conformance

    @Test func operationToolCanBeRegisteredOnALanguageModelSession() throws {
        let tool = try makeTool()

        let session = LanguageModelSession(tools: [tool], instructions: "Test session")

        #expect(session.transcript.isEmpty == false)
    }

    // MARK: - Dispatch: exact / aliased / reordered op strings

    @Test func dispatchesExactOpString() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "add note", "title": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func dispatchesCaseInsensitiveOpString() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "ADD NOTE", "title": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func dispatchesReorderedOpString() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "note add", "title": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func dispatchesVerbAliasOpString() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "create note", "title": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func dispatchesCaseInsensitiveVerbAliasOpString() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "CREATE NOTE", "title": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func dispatchesSeparatorNormalizedOpString() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "add_note", "title": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    // MARK: - Unknown op: returned, not thrown

    @Test func unknownOpReturnsCorrectiveMessageListingValidOps() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "frobnicate widget"])

        let message = try await tool.call(arguments: arguments)

        #expect(message.contains("add note"))
        #expect(message.contains("delete note"))
    }

    @Test func missingOpFieldEntirelyReturnsCorrectiveMessage() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["title": "Groceries"])

        let message = try await tool.call(arguments: arguments)

        #expect(message.contains("add note"))
    }

    // MARK: - Missing required: returned, not thrown

    @Test func missingRequiredReturnsCorrectiveMessageNamingTheParameter() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "add note"])

        let message = try await tool.call(arguments: arguments)

        #expect(message.contains("title"))
    }

    // MARK: - decodingFailed: returned, not thrown

    @Test func decodingFailedFromOperationInitReturnsCorrectiveMessageInsteadOfThrowing() async throws {
        // `DecodingFailureToolFixture` declares a required `title` the
        // resolver can always find, so `resolution.missingRequired` is
        // empty and dispatch reaches `operation.run` — but its `init(_:)`
        // unconditionally throws, so `AnyOperation.run` throws
        // `OperationError.decodingFailed`, distinct from the
        // missing-required-parameter path above.
        let tool = try OperationTool(
            name: "notes",
            description: "Note operations",
            context: ToolFixtureContext(),
            operations: [AnyOperation(DecodingFailureToolFixture.self)]
        )
        let arguments = GeneratedContent(properties: ["op": "fail decode", "title": "Groceries"])

        let message = try await tool.call(arguments: arguments)

        #expect(message == OperationError.decodingFailed.description)
    }

    // MARK: - Key-alias normalization

    @Test func keyAliasResolvesDeclaredAliasToCanonicalName() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "add note", "name": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    @Test func keyAliasResolvesLabelsAliasToTagsCanonicalName() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "add note", "title": "Groceries", "labels": ["errands"]])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"tags\":[\"errands\"]"))
    }

    @Test func keyAliasCamelSnakeNormalizationResolvesUnaliasedParameter() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "add note", "title": "Groceries", "author_name": "Ann"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"authorName\":\"Ann\""))
    }

    @Test func explicitCanonicalKeyIsNeverOverriddenByAnAlias() async throws {
        let tool = try makeTool()
        // Both the canonical "title" and its alias "name" are present;
        // the canonical value must win.
        let arguments = GeneratedContent(properties: ["op": "add note", "title": "Canonical", "name": "Aliased"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Canonical\""))
    }

    @Test func explicitCanonicalKeyIsNeverOverriddenByANormalizedKeyMatch() async throws {
        let tool = try makeTool()
        // Both the canonical "authorName" and its snake_case normalized
        // form "author_name" (an unaliased normalization match, not a
        // declared alias) are present; the canonical value must win.
        let arguments = GeneratedContent(properties: [
            "op": "add note", "title": "Groceries", "authorName": "Canonical", "author_name": "Normalized",
        ])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"authorName\":\"Canonical\""))
    }

    // MARK: - Inference hook

    @Test func inferenceHookProposesOpStringWhenOpFieldIsAbsent() async throws {
        let resolver = OperationResolver(inferOp: { content in
            // Infers "add note" whenever a "title" field is present and no
            // explicit "op" was given.
            (try? content.value(String.self, forProperty: "title")) != nil ? "add note" : nil
        })
        let tool = try makeTool(resolver: resolver)
        let arguments = GeneratedContent(properties: ["title": "Groceries"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
    }

    // MARK: - Extra `op` key tolerance (stripped before typed construction)

    @Test func extraOpKeyDoesNotBreakTypedConstruction() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "add note", "title": "Groceries", "tags": ["errands"]])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"title\":\"Groceries\""))
        #expect(json.contains("\"tags\":[\"errands\"]"))
    }

    // MARK: - Retry cap

    @Test func retryCapReturnsTerminalMessageOnlyOnTheThirdConsecutiveFailure() async throws {
        let tool = try makeTool(retryCap: 2)
        let arguments = GeneratedContent(properties: ["op": "frobnicate widget"])

        let first = try await tool.call(arguments: arguments)
        let second = try await tool.call(arguments: arguments)
        let third = try await tool.call(arguments: arguments)

        #expect(first.contains("add note"))
        #expect(second.contains("add note"))
        #expect(first == second)
        #expect(third != first)
        #expect(third.contains("stopping"))
    }

    @Test func retryCapCounterResetsAfterASuccessfulDispatch() async throws {
        let tool = try makeTool(retryCap: 2)
        let badArguments = GeneratedContent(properties: ["op": "frobnicate widget"])
        let goodArguments = GeneratedContent(properties: ["op": "add note", "title": "Groceries"])

        _ = try await tool.call(arguments: badArguments)
        _ = try await tool.call(arguments: goodArguments)
        let afterSuccess = try await tool.call(arguments: badArguments)

        #expect(afterSuccess.contains("add note"))
        #expect(afterSuccess.contains("stopping") == false)
    }

    @Test func retryCapCounterResetsAfterTheTerminalMessage() async throws {
        let tool = try makeTool(retryCap: 2)
        let arguments = GeneratedContent(properties: ["op": "frobnicate widget"])

        _ = try await tool.call(arguments: arguments)
        _ = try await tool.call(arguments: arguments)
        let terminal = try await tool.call(arguments: arguments)
        let afterTerminal = try await tool.call(arguments: arguments)

        #expect(terminal.contains("stopping"))
        #expect(afterTerminal.contains("add note"))
        #expect(afterTerminal.contains("stopping") == false)
    }

    // MARK: - matchOpString: non-two-token fallback (exact-joined-token match)
    //
    // Every dispatch test above supplies an opString that tokenizes to
    // exactly 2 words, so these exercise `matchOpString` directly (it's
    // `internal`, reachable via `@testable import`) against the fallback
    // branch taken when the tokenized opString isn't a verb/noun pair.

    @Test func matchOpStringSingleTokenExactlyMatchingACandidatesOwnSingleTokenFormReturnsIt() {
        let resolver = OperationResolver()
        let candidates = [
            OperationResolver.OpCandidate(verb: "add", noun: "note", opString: "addnote"),
            OperationResolver.OpCandidate(verb: "delete", noun: "note", opString: "delete note"),
        ]

        let matched = resolver.matchOpString("addnote", against: candidates)

        #expect(matched == "addnote")
    }

    @Test func matchOpStringSingleTokenWithNoEquivalentCandidateReturnsNil() {
        let resolver = OperationResolver()
        let candidates = [
            OperationResolver.OpCandidate(verb: "add", noun: "note", opString: "addnote"),
            OperationResolver.OpCandidate(verb: "delete", noun: "note", opString: "delete note"),
        ]

        let matched = resolver.matchOpString("frobnicate", against: candidates)

        #expect(matched == nil)
    }

    @Test func matchOpStringSingleTokenIsCaseInsensitiveAgainstACandidatesOwnSingleTokenForm() {
        let resolver = OperationResolver()
        let candidates = [
            OperationResolver.OpCandidate(verb: "add", noun: "note", opString: "addnote"),
            OperationResolver.OpCandidate(verb: "delete", noun: "note", opString: "delete note"),
        ]

        let matched = resolver.matchOpString("ADDNOTE", against: candidates)

        #expect(matched == "addnote")
    }

    @Test func matchOpStringThreeTokensExactlyMatchingACandidatesEquivalentTokenizationReturnsIt() {
        let resolver = OperationResolver()
        let candidates = [
            OperationResolver.OpCandidate(verb: "add", noun: "note", opString: "add_the_note"),
            OperationResolver.OpCandidate(verb: "delete", noun: "note", opString: "delete note"),
        ]

        let matched = resolver.matchOpString("add the note", against: candidates)

        #expect(matched == "add_the_note")
    }

    @Test func matchOpStringThreeTokensWithNoEquivalentCandidateReturnsNil() {
        let resolver = OperationResolver()
        let candidates = [
            OperationResolver.OpCandidate(verb: "add", noun: "note", opString: "addnote"),
            OperationResolver.OpCandidate(verb: "delete", noun: "note", opString: "delete note"),
        ]

        let matched = resolver.matchOpString("add the note", against: candidates)

        #expect(matched == nil)
    }

    @Test func matchOpStringThreeTokensIsCaseInsensitiveAgainstACandidatesEquivalentTokenization() {
        let resolver = OperationResolver()
        let candidates = [
            OperationResolver.OpCandidate(verb: "add", noun: "note", opString: "add_the_note"),
            OperationResolver.OpCandidate(verb: "delete", noun: "note", opString: "delete note"),
        ]

        let matched = resolver.matchOpString("ADD THE NOTE", against: candidates)

        #expect(matched == "add_the_note")
    }

    // MARK: - resolveParameters: non-structure top-level content
    //
    // Every dispatch test above supplies a top-level structure payload
    // (`GeneratedContent(properties:)`), so `resolveParameters`'s
    // `.structure`-vs-else branch (it's `internal`, reachable via
    // `@testable import`) only ever sees the `.structure` side there. These
    // exercise the `else` side directly: a top-level `GeneratedContent`
    // whose `kind` is a bare scalar or a top-level array, rather than an
    // object. Resolution must degrade gracefully — treating the payload as
    // having no properties at all, so every required parameter comes back
    // missing — rather than crash.

    @Test func resolveParametersOnATopLevelScalarStringReportsEveryRequiredParameterMissing() {
        let resolver = OperationResolver()
        let parameters: [ParamMeta] = [
            ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
            ParamMeta(name: "tags", type: .array(of: .string), required: false, description: "Tags to attach"),
        ]
        let content = GeneratedContent(kind: .string("just a string, not an object"))

        let resolution = resolver.resolveParameters(content, matching: parameters)

        #expect(resolution.missingRequired == ["title"])
        #expect(resolution.content == GeneratedContent(kind: .structure(properties: [:], orderedKeys: [])))
    }

    @Test func resolveParametersOnATopLevelArrayReportsEveryRequiredParameterMissing() {
        let resolver = OperationResolver()
        let parameters: [ParamMeta] = [
            ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
            ParamMeta(name: "tags", type: .array(of: .string), required: false, description: "Tags to attach"),
        ]
        let content = GeneratedContent(kind: .array([
            GeneratedContent(kind: .string("first")),
            GeneratedContent(kind: .string("second")),
        ]))

        let resolution = resolver.resolveParameters(content, matching: parameters)

        #expect(resolution.missingRequired == ["title"])
        #expect(resolution.content == GeneratedContent(kind: .structure(properties: [:], orderedKeys: [])))
    }
}
