import FoundationModels
import FoundationModelsExtras
import Testing

/// The error that `DescribingToolFixture.perform(_:)` throws when it cannot dispatch a payload.
private enum DescribingToolFixtureError: Error, Equatable {
    /// The payload names an operation that the fixture does not have.
    case unknownOperation(String)
}

/// A tool that conforms to `OperationDescribing` by hand.
/// It uses only the core module, not `Operations`.
private struct DescribingToolFixture: OperationDescribing {
    typealias Arguments = GeneratedContent
    typealias Output = String

    /// The op string of the one operation that the fixture has.
    static let greetOpString = "greet person"

    /// The text that a successful `greet person` operation returns.
    static let greetOutput = "hello"

    let name = "describing"
    let description = "A tool that describes its operations"
    let parameters: GenerationSchema

    init() throws {
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: name, description: description, properties: []),
            dependencies: []
        )
    }

    var operationDescriptors: [OperationDescriptor] {
        [DescribingToolFixture.greetDescriptor]
    }

    /// The descriptor of the `greet person` operation.
    static let greetDescriptor = OperationDescriptor(
        verb: "greet",
        noun: "person",
        opString: greetOpString,
        description: "Greets a person",
        parameters: [
            OperationParameterDescriptor(
                name: "name",
                type: .string,
                required: true,
                description: "The name of the person",
                aliases: ["who"],
                allowedValues: nil
            ),
            OperationParameterDescriptor(
                name: "tags",
                type: .array(of: .string),
                required: false,
                description: "Tags for the greeting",
                aliases: [],
                allowedValues: ["formal", "casual"]
            ),
        ]
    )

    func perform(_ arguments: GeneratedContent) async throws -> String {
        let op = try arguments.value(String.self, forProperty: "op")
        guard op == DescribingToolFixture.greetOpString else {
            throw DescribingToolFixtureError.unknownOperation(op)
        }
        return DescribingToolFixture.greetOutput
    }

    func call(arguments: GeneratedContent) async throws -> String {
        do {
            return try await perform(arguments)
        } catch {
            return "refused: \(error)"
        }
    }
}

/// A plain `Tool` that does not conform to `OperationDescribing`.
private struct PlainToolFixture: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name = "plain"
    let description = "Does not describe its operations"
    let parameters: GenerationSchema

    init() throws {
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: name, description: description, properties: []),
            dependencies: []
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        "plain-output"
    }
}

/// Tests for `OperationDescribing` and its type-erased descriptor types.
@Suite struct OperationDescribingTests {
    @Test func castFromAnyToolFindsADescribingTool() throws {
        let tool: any Tool = try DescribingToolFixture()

        let describing = try #require(tool as? any OperationDescribing)

        #expect(describing.operationDescriptors == [DescribingToolFixture.greetDescriptor])
    }

    @Test func castFromAnyToolReturnsNilForAPlainTool() throws {
        let tool: any Tool = try PlainToolFixture()

        #expect((tool as? any OperationDescribing) == nil)
    }

    @Test func descriptorsWithTheSameFieldsAreEqual() {
        let copy = OperationDescriptor(
            verb: "greet",
            noun: "person",
            opString: DescribingToolFixture.greetOpString,
            description: "Greets a person",
            parameters: DescribingToolFixture.greetDescriptor.parameters
        )

        #expect(copy == DescribingToolFixture.greetDescriptor)
    }

    @Test func descriptorsWithADifferentParameterTypeAreNotEqual() {
        let original = DescribingToolFixture.greetDescriptor.parameters[1]
        let changed = OperationParameterDescriptor(
            name: original.name,
            type: .array(of: .integer),
            required: original.required,
            description: original.description,
            aliases: original.aliases,
            allowedValues: original.allowedValues
        )

        #expect(changed != original)
    }

    @Test func performReturnsTheOutputForAKnownOp() async throws {
        let tool: any Tool = try DescribingToolFixture()
        let describing = try #require(tool as? any OperationDescribing)

        let output = try await describing.perform(
            GeneratedContent(properties: ["op": DescribingToolFixture.greetOpString, "name": "Ada"])
        )

        #expect(output == DescribingToolFixture.greetOutput)
    }

    @Test func performThrowsForAnUnknownOp() async throws {
        let tool: any Tool = try DescribingToolFixture()
        let describing = try #require(tool as? any OperationDescribing)

        await #expect(throws: DescribingToolFixtureError.unknownOperation("fly person")) {
            try await describing.perform(GeneratedContent(properties: ["op": "fly person"]))
        }
    }
}
