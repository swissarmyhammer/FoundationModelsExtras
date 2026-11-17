import FoundationModels
import Testing

@testable import Operations

/// Shared `Context` for the skills-mirror fixture operations below. Each
/// operation answers with its own op string and the `id` it decoded, so the
/// context carries no state.
private struct SkillsMirrorContext: Sendable {}

/// What each skills-mirror operation answers: the op that ran and the `id`
/// it decoded, so a test can tell both the dispatch and the payload.
private struct SkillsMirrorOutput: Encodable, Sendable, Equatable {
    let op: String
    let id: String?
}

/// One operation of the skills mirror. A conforming type states
/// only its verb, noun, and parameters. This extension gives the rest: a
/// decode that reads the optional `id`, and an `execute(in:)` that answers
/// with the op string and that `id`.
private protocol SkillsMirrorOperation: OperationDefinition
where Context == SkillsMirrorContext, Output == SkillsMirrorOutput {
    /// The `id` that the payload held, or `nil`.
    var id: String? { get }

    /// Makes the operation with the decoded `id`.
    init(id: String?)
}

extension SkillsMirrorOperation {
    /// A schema with no properties: the resolver reads `parameterMetadata`,
    /// not this schema.
    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: operationDescription, properties: [])
    }

    /// A one-line description; the tests never read it.
    static var operationDescription: String { "The \(opString) operation of the skills mirror" }

    /// Reads the optional `id` of the resolved payload.
    init(_ content: GeneratedContent) throws {
        self.init(id: try? content.value(String.self, forProperty: "id"))
    }

    /// The `id`, when there is one.
    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["id": id])
    }

    /// Answers with the op string and the decoded `id`.
    func execute(in context: SkillsMirrorContext) async throws -> SkillsMirrorOutput {
        SkillsMirrorOutput(op: Self.opString, id: id)
    }
}

/// `search skill`: a required `query` and an optional `limit`, as
/// FoundationModelsSkills declares it. It only reads, so it is inferable.
private struct SearchSkillMirror: SkillsMirrorOperation {
    let id: String?
    static let isInferable = true
    static let verb = "search"
    static let noun = "skill"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "query", type: .string, required: true, description: "The search query."),
        ParamMeta(name: "limit", type: .integer, required: false, description: "The most matches to give."),
    ]
}

/// `list skill`: an optional `filter` only. It only reads, so it is
/// inferable.
private struct ListSkillMirror: SkillsMirrorOperation {
    let id: String?
    static let isInferable = true
    static let verb = "list"
    static let noun = "skill"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "filter", type: .string, required: false, description: "Text a listed skill must hold.")
    ]
}

/// `use skill`: a required `id` and an optional `arguments` array. It
/// declares a background mount, unlike the other mirrors, so a test can
/// tell from the mount that this operation was the one found. It only reads,
/// so it is inferable.
private struct UseSkillMirror: SkillsMirrorOperation {
    let id: String?
    static let isInferable = true
    static let verb = "use"
    static let noun = "skill"
    static let mount = ToolMount(mode: .background)
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The id of the skill to load."),
        ParamMeta(name: "arguments", type: .array(of: .string), required: false, description: "The skill arguments."),
    ]
}

/// `list resource`: a required `id` only, so `{id}` fits it as well as
/// `use skill`. It only reads, so it is inferable.
private struct ListResourceMirror: SkillsMirrorOperation {
    let id: String?
    static let isInferable = true
    static let verb = "list"
    static let noun = "resource"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The skill id whose resources to list.")
    ]
}

/// `read resource`: a required `id` and `path`, an optional `start` and
/// `end`. It only reads, so it is inferable.
private struct ReadResourceMirror: SkillsMirrorOperation {
    let id: String?
    static let isInferable = true
    static let verb = "read"
    static let noun = "resource"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The skill id owning the resource."),
        ParamMeta(name: "path", type: .string, required: true, description: "The resource path."),
        ParamMeta(name: "start", type: .integer, required: false, description: "The first line."),
        ParamMeta(name: "end", type: .integer, required: false, description: "The last line."),
    ]
}

/// `run script`: a required `id` and `path`, an optional `arguments` array
/// and `timeout`. It sets `isInferable` to `false`, so a call must name it.
private struct RunScriptMirror: SkillsMirrorOperation {
    let id: String?
    static let isInferable = false
    static let verb = "run"
    static let noun = "script"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The skill id owning the script."),
        ParamMeta(name: "path", type: .string, required: true, description: "The script path."),
        ParamMeta(name: "arguments", type: .array(of: .string), required: false, description: "The script arguments."),
        ParamMeta(name: "timeout", type: .integer, required: false, description: "The timeout in seconds."),
    ]
}

/// The tolerant argument shapes of `OperationTool`: a lone
/// `arguments` wrapper is unwrapped, and a missing `op` is inferred from the
/// keys, over a fixture that mirrors the six operations of the real
/// FoundationModelsSkills `skills` tool. The evidence shapes are the calls
/// Recursive Flint made on a SWE-bench run.
@Suite("OperationTool argument tolerance")
struct OperationArgumentToleranceTests {
    /// The prefix of the "Unknown operation" corrective.
    private static let unknownOperationPrefix = "Unknown operation."

    /// The prefix of the corrective for a call that names no operation and
    /// infers none.
    private static let unnamedOperationPrefix = "No operation is named."

    /// Makes the skills-mirror tool, in the operation order of the real tool.
    ///
    /// - Parameter defaultOp: The resolver's default op, or `nil` for none.
    /// - Returns: The fused tool.
    private func makeSkillsMirror(defaultOp: String? = "use skill") throws -> OperationTool<SkillsMirrorContext> {
        try OperationTool(
            name: "skills",
            description: "A mirror of the skills tool",
            context: SkillsMirrorContext(),
            operations: [
                AnyOperation(SearchSkillMirror.self),
                AnyOperation(ListSkillMirror.self),
                AnyOperation(UseSkillMirror.self),
                AnyOperation(ListResourceMirror.self),
                AnyOperation(ReadResourceMirror.self),
                AnyOperation(RunScriptMirror.self),
            ],
            resolver: OperationResolver(defaultOp: defaultOp)
        )
    }

    /// The JSON answer of `op` with `id`, as `AnyOperation.run` encodes it.
    private func answer(_ op: String, id: String? = nil) -> String {
        guard let id else { return #"{"op":"\#(op)"}"# }
        return #"{"id":"\#(id)","op":"\#(op)"}"#
    }

    // MARK: - Missing `op`

    @Test func opLessIdDispatchesToTheDefaultOpOfTheSkillsMirror() async throws {
        let tool = try makeSkillsMirror()

        let json = try await tool.call(arguments: GeneratedContent(properties: ["id": "kanban"]))

        #expect(json == answer("use skill", id: "kanban"))
    }

    @Test func opLessIdThatFitsTwoOperationsIsNotInferredWithoutADefaultOp() async throws {
        let tool = try makeSkillsMirror(defaultOp: nil)

        let message = try await tool.call(arguments: GeneratedContent(properties: ["id": "kanban"]))

        #expect(message.hasPrefix(Self.unnamedOperationPrefix))
    }

    @Test func opLessKeysThatFitExactlyOneOperationInferIt() async throws {
        let tool = try makeSkillsMirror(defaultOp: nil)

        let json = try await tool.call(arguments: GeneratedContent(properties: ["query": "kanban"]))

        #expect(json == answer("search skill"))
    }

    @Test func opLessKeysThatFitSeveralOperationsButNotTheDefaultOpAreNotInferred() async throws {
        let tool = try makeSkillsMirror(defaultOp: "search skill")

        let message = try await tool.call(arguments: GeneratedContent(properties: ["id": "kanban"]))

        #expect(message.hasPrefix(Self.unnamedOperationPrefix))
    }

    @Test func opLessKeysThatFitAnInferableAndANonInferableOperationRunTheInferableOne() async throws {
        let tool = try makeSkillsMirror()

        let json = try await tool.call(arguments: GeneratedContent(properties: ["id": "kanban", "path": "SKILL.md"]))

        #expect(json == answer("read resource", id: "kanban"))
    }

    @Test func opLessKeysThatFitOnlyANonInferableOperationAreNotInferred() async throws {
        let tool = try makeSkillsMirror()
        let arguments = GeneratedContent(properties: ["id": "kanban", "path": "run.sh", "timeout": 5])

        let message = try await tool.call(arguments: arguments)

        #expect(message.hasPrefix(Self.unnamedOperationPrefix))
    }

    @Test func opLessKeysThatFitNoOperationAreNotInferred() async throws {
        let tool = try makeSkillsMirror()

        let message = try await tool.call(arguments: GeneratedContent(properties: ["skill": "kanban"]))

        #expect(message.hasPrefix(Self.unnamedOperationPrefix))
    }

    @Test func emptyPayloadIsNotInferredToAnOperationWithNoRequiredParameter() async throws {
        let tool = try makeSkillsMirror(defaultOp: nil)

        let message = try await tool.call(arguments: GeneratedContent(properties: [:]))

        #expect(message.hasPrefix(Self.unnamedOperationPrefix))
    }

    @Test func emptyOpStringIsInferredFromTheKeys() async throws {
        let tool = try makeSkillsMirror()

        let json = try await tool.call(arguments: GeneratedContent(properties: ["op": "", "id": "kanban"]))

        #expect(json == answer("use skill", id: "kanban"))
    }

    @Test func unnamedOperationMessageListsTheFittingAndTheValidOperations() async throws {
        let tool = try makeSkillsMirror(defaultOp: nil)

        let message = try await tool.call(arguments: GeneratedContent(properties: ["id": "kanban"]))

        let fitting = ["use skill", "list resource"]
        #expect(message == OperationError.unnamedOperation(fitting: fitting, valid: tool.operations.map(\.opString)).description)
    }

    // MARK: - A lone `arguments` wrapper

    @Test func loneArgumentsObjectIsUnwrapped() async throws {
        let tool = try makeSkillsMirror(defaultOp: nil)
        let inner = GeneratedContent(properties: ["id": "kanban", "op": "use skill"])

        let json = try await tool.call(arguments: GeneratedContent(properties: ["arguments": inner]))

        #expect(json == answer("use skill", id: "kanban"))
    }

    @Test func loneArgumentsJSONStringOfAnObjectIsUnwrapped() async throws {
        let tool = try makeSkillsMirror(defaultOp: nil)
        let arguments = try GeneratedContent(json: #"{"arguments": "{\"id\": \"kanban\", \"op\": \"use skill\"}"}"#)

        let json = try await tool.call(arguments: arguments)

        #expect(json == answer("use skill", id: "kanban"))
    }

    @Test func loneArgumentsIsUnwrappedBeforeTheOpIsInferred() async throws {
        let tool = try makeSkillsMirror()
        let inner = GeneratedContent(properties: ["id": "code-analyzing"])

        let json = try await tool.call(arguments: GeneratedContent(properties: ["arguments": inner]))

        #expect(json == answer("use skill", id: "code-analyzing"))
    }

    @Test func loneArgumentsJSONStringOfANonObjectIsNotUnwrapped() async throws {
        let tool = try makeSkillsMirror()
        let arguments = try GeneratedContent(json: #"{"arguments": "[\"kanban\"]"}"#)

        let message = try await tool.call(arguments: arguments)

        #expect(message.hasPrefix(Self.unnamedOperationPrefix))
    }

    // MARK: - Well-formed arguments

    @Test func explicitOpIsNeverOverriddenByTheDefaultOp() async throws {
        let tool = try makeSkillsMirror()

        let json = try await tool.call(arguments: GeneratedContent(properties: ["op": "list resource", "id": "kanban"]))

        #expect(json == answer("list resource", id: "kanban"))
    }

    @Test func explicitOpUnderAKeyThatNormalizesToOpRunsTheNamedOperation() async throws {
        let tool = try makeSkillsMirror()

        let json = try await tool.call(arguments: GeneratedContent(properties: ["OP": "list resource", "id": "kanban"]))

        #expect(json == answer("list resource", id: "kanban"))
    }

    @Test func keyOpWinsOverAnotherKeyThatNormalizesToOp() async throws {
        let tool = try makeSkillsMirror()

        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["OP": "use skill", "op": "list resource", "id": "kanban"]))

        #expect(json == answer("list resource", id: "kanban"))
    }

    @Test func explicitUnknownOpIsNotReplacedByAnInferredOne() async throws {
        let tool = try makeSkillsMirror()

        let message = try await tool.call(arguments: GeneratedContent(properties: ["op": "frobnicate", "id": "kanban"]))

        #expect(message.hasPrefix(Self.unknownOperationPrefix))
    }

    @Test func argumentsBesideAnExplicitOpStayTheParameterOfTheOperation() async throws {
        let tool = try makeSkillsMirror()

        let json = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "use skill", "id": "kanban", "arguments": ["fast"]]))

        #expect(json == answer("use skill", id: "kanban"))
    }

    // MARK: - Mount

    @Test func mountSeesTheOperationOfAnUnwrappedAndInferredPayload() throws {
        let tool = try makeSkillsMirror()
        let inner = GeneratedContent(properties: ["id": "kanban"])

        let mount = tool.mount(for: GeneratedContent(properties: ["arguments": inner]))

        #expect(mount == UseSkillMirror.mount)
    }
}
