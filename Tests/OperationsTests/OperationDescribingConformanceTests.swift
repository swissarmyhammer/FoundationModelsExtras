import FoundationModels
import FoundationModelsExtras
import Testing

@testable import Operations

/// JSON-encodable result of `ParameterTypesFixture.execute(in:)`.
private struct ParameterTypesOutput: Encodable, Sendable {
    let name: String
    let count: Int
}

/// `configure widget` fixture: one parameter for each `ParamType` case, with
/// a short flag, aliases and allowed values, so that a test can examine each
/// field of the descriptor mapping.
private struct ParameterTypesFixture: OperationDefinition {
    typealias Context = FixtureContext
    typealias Output = ParameterTypesOutput

    var name: String
    var count: Int

    static let verb = "configure"
    static let noun = "widget"
    static let operationDescription = "Configures a widget"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "name", type: .string, required: true, description: "The widget name", short: "n", aliases: ["label"]),
        ParamMeta(name: "count", type: .integer, required: true, description: "How many widgets"),
        ParamMeta(name: "ratio", type: .number, required: false, description: "The size ratio"),
        ParamMeta(name: "enabled", type: .boolean, required: false, description: "Whether the widget is on"),
        ParamMeta(name: "grid", type: .array(of: .array(of: .integer)), required: false, description: "The cell grid"),
        ParamMeta(name: "mode", type: .string, required: false, description: "The run mode", allowedValues: ["fast", "slow"]),
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: ParameterTypesFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        name = try content.value(String.self, forProperty: "name")
        count = try content.value(Int.self, forProperty: "count")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["name": name, "count": count])
    }

    func execute(in context: FixtureContext) async throws -> ParameterTypesOutput {
        ParameterTypesOutput(name: name, count: count)
    }
}

/// JSON-encodable result of `TagNoteFixture.execute(in:)`.
private struct TagNoteFixtureOutput: Encodable, Sendable {
    let id: String
    let tags: [String]
}

/// `tag note` fixture: a required `id` and a required `tags` array, so that
/// a test can send the same payload to `perform(_:)` and to `call(arguments:)`.
private struct TagNoteFixture: OperationDefinition {
    typealias Context = FixtureContext
    typealias Output = TagNoteFixtureOutput

    var id: String
    var tags: [String]

    static let verb = "tag"
    static let noun = "note"
    static let operationDescription = "Attach tags to a note"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The note id"),
        ParamMeta(name: "tags", type: .array(of: .string), required: true, description: "Tags to attach"),
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: TagNoteFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        id = try content.value(String.self, forProperty: "id")
        tags = try content.value([String].self, forProperty: "tags")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["id": id, "tags": tags])
    }

    func execute(in context: FixtureContext) async throws -> TagNoteFixtureOutput {
        TagNoteFixtureOutput(id: id, tags: tags)
    }
}

struct OperationDescribingConformanceTests {

    /// The op strings of `makeTool`, in registration order.
    private static let registeredOpStrings = ["echo message", "boom encode", "configure widget", "tag note"]

    private func makeTool(context: FixtureContext = FixtureContext(), retryCap: Int = 2) throws -> OperationTool<FixtureContext> {
        try OperationTool(
            name: "fixtures",
            description: "Fixture operations",
            context: context,
            operations: [
                AnyOperation(FixtureOperation.self),
                AnyOperation(FailingEncodeOperation.self),
                AnyOperation(ParameterTypesFixture.self),
                AnyOperation(TagNoteFixture.self),
            ],
            retryCap: retryCap
        )
    }

    private func descriptor(_ opString: String, of tool: OperationTool<FixtureContext>) throws -> OperationDescriptor {
        try #require(tool.operationDescriptors.first { $0.opString == opString })
    }

    // MARK: - Conformance

    @Test func operationToolCastsFromAnyToolToAnyOperationDescribing() throws {
        let tool: any Tool = try makeTool()

        #expect(tool is any OperationDescribing)
    }

    // MARK: - operationDescriptors

    @Test func operationDescriptorsFollowTheRegistrationOrder() throws {
        let tool = try makeTool()

        #expect(tool.operationDescriptors.map(\.opString) == Self.registeredOpStrings)
    }

    @Test func echoMessageDescriptorCopiesTheOperationMetadata() throws {
        let tool = try makeTool()

        let echo = try descriptor("echo message", of: tool)

        #expect(
            echo
                == OperationDescriptor(
                    verb: "echo",
                    noun: "message",
                    opString: "echo message",
                    description: "Echoes a message back with its length",
                    parameters: [
                        OperationParameterDescriptor(
                            name: "message",
                            type: .string,
                            required: true,
                            description: "The message to echo",
                            aliases: [],
                            allowedValues: nil
                        )
                    ]
                )
        )
    }

    @Test func boomEncodeDescriptorHasNoParameters() throws {
        let tool = try makeTool()

        let boom = try descriptor("boom encode", of: tool)

        #expect(boom.verb == "boom")
        #expect(boom.noun == "encode")
        #expect(boom.description == "Always fails to JSON-encode its output")
        #expect(boom.parameters.isEmpty)
    }

    @Test func parameterDescriptorsMapEachParamTypeCaseAndEachField() throws {
        let tool = try makeTool()

        let configure = try descriptor("configure widget", of: tool)

        #expect(
            configure.parameters == [
                OperationParameterDescriptor(
                    name: "name", type: .string, required: true, description: "The widget name", aliases: ["label"], allowedValues: nil
                ),
                OperationParameterDescriptor(
                    name: "count", type: .integer, required: true, description: "How many widgets", aliases: [], allowedValues: nil
                ),
                OperationParameterDescriptor(
                    name: "ratio", type: .number, required: false, description: "The size ratio", aliases: [], allowedValues: nil
                ),
                OperationParameterDescriptor(
                    name: "enabled", type: .boolean, required: false, description: "Whether the widget is on", aliases: [],
                    allowedValues: nil
                ),
                OperationParameterDescriptor(
                    name: "grid", type: .array(of: .array(of: .integer)), required: false, description: "The cell grid",
                    aliases: [], allowedValues: nil
                ),
                OperationParameterDescriptor(
                    name: "mode", type: .string, required: false, description: "The run mode", aliases: [],
                    allowedValues: ["fast", "slow"]
                ),
            ]
        )
    }

    // MARK: - perform: success

    @Test func performGivesTheSameJSONAsCallForTheSamePayload() async throws {
        let arguments = GeneratedContent(properties: ["op": "tag note", "id": "note-1", "tags": ["a"]])

        let performed = try await makeTool().perform(arguments)
        let called = try await makeTool().call(arguments: arguments)

        #expect(performed == called)
        #expect(performed == "{\"id\":\"note-1\",\"tags\":[\"a\"]}")
    }

    @Test func performWorksThroughAnAnyOperationDescribingValue() async throws {
        let tool: any Tool = try makeTool()
        let describing = try #require(tool as? any OperationDescribing)

        let json = try await describing.perform(GeneratedContent(properties: ["op": "echo message", "message": "hi"]))

        #expect(json == "{\"echoed\":\"hi\",\"length\":2}")
    }

    // MARK: - perform: refusals are thrown

    @Test func performThrowsUnknownOperationForAnUnknownOp() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "frobnicate widget"])

        await #expect(throws: OperationError.unknownOperation(valid: Self.registeredOpStrings)) {
            try await tool.perform(arguments)
        }
    }

    @Test func callStillReturnsTheCorrectiveTextForAnUnknownOp() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "frobnicate widget"])

        let message = try await tool.call(arguments: arguments)

        #expect(message == OperationError.unknownOperation(valid: Self.registeredOpStrings).description)
    }

    @Test func performThrowsMissingRequiredForAnAbsentRequiredField() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "tag note", "id": "note-1"])

        await #expect(throws: OperationError.missingRequired(["tags"])) {
            try await tool.perform(arguments)
        }
    }

    @Test func performThrowsDecodingFailedForAValueOfTheWrongType() async throws {
        let tool = try makeTool()
        let arguments = GeneratedContent(properties: ["op": "configure widget", "name": "w", "count": "many"])

        await #expect(throws: OperationError.decodingFailed) {
            try await tool.perform(arguments)
        }
    }

    @Test func performThrowsExecutionFailedWithTheCause() async throws {
        let tool = try makeTool(context: FixtureContext(shouldFail: true))
        let arguments = GeneratedContent(properties: ["op": "echo message", "message": "hi"])

        do {
            _ = try await tool.perform(arguments)
            Issue.record("expected OperationError.executionFailed to be thrown")
        } catch let error as OperationError {
            #expect(error.description == "This operation failed while executing. Cause: The fixture store is offline.")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - perform: the retry cap

    @Test func performRefusalsDoNotCountTowardTheRetryCapOfALaterCall() async throws {
        let retryCap = 1
        let tool = try makeTool(retryCap: retryCap)
        let missingTags = GeneratedContent(properties: ["op": "tag note", "id": "note-1"])

        for _ in 0...retryCap {
            await #expect(throws: OperationError.missingRequired(["tags"])) {
                try await tool.perform(missingTags)
            }
        }
        let message = try await tool.call(arguments: GeneratedContent(properties: ["op": "frobnicate widget"]))

        #expect(message == OperationError.unknownOperation(valid: Self.registeredOpStrings).description)
    }

    @Test func performSuccessDoesNotResetTheRetryCapOfCall() async throws {
        let tool = try makeTool(retryCap: 1)
        let unknownOp = GeneratedContent(properties: ["op": "frobnicate widget"])

        _ = try await tool.call(arguments: unknownOp)
        _ = try await tool.perform(GeneratedContent(properties: ["op": "echo message", "message": "hi"]))
        let second = try await tool.call(arguments: unknownOp)

        #expect(second.contains("stopping"))
    }
}
