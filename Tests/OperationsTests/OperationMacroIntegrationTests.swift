import FoundationModels
import Testing

@testable import Operations

/// Context passed to `AddNoteFixture.execute(in:)`.
private struct NotesFixtureContext: Sendable {
    var notes: [String] = []
}

/// JSON-encodable result produced by `AddNoteFixture.execute(in:)`.
private struct AddNoteFixtureOutput: Encodable, Sendable, Equatable {
    let title: String
    let tagCount: Int
}

/// A real `@Generable @Operation(...)` struct — proving, under the actual
/// Swift compiler (not the `assertMacroExpansion` simulation harness), that
/// `@Operation` synthesizes `OperationDefinition` conformance with a correct
/// `parameterMetadata` table plan.md's "Declaring an operation" describes.
@Generable
@Operation(verb: "add", noun: "note", description: "Create a new note")
private struct AddNoteFixture {
    @Guide(description: "The note title")
    @OperationParam(short: "t", aliases: ["name"])
    var title: String

    /// Markdown body of the note.
    var body: String?

    @Guide(description: "Tags to attach")
    var tags: [String]?
}

extension AddNoteFixture {
    func execute(in context: NotesFixtureContext) async throws -> AddNoteFixtureOutput {
        AddNoteFixtureOutput(title: title, tagCount: tags?.count ?? 0)
    }
}

@Suite struct OperationMacroIntegrationTests {

    @Test func macroSynthesizesVerbNounAndDescription() {
        #expect(AddNoteFixture.verb == "add")
        #expect(AddNoteFixture.noun == "note")
        #expect(AddNoteFixture.operationDescription == "Create a new note")
        #expect(AddNoteFixture.opString == "add note")
    }

    @Test func macroSynthesizesParameterMetadataFromStoredProperties() {
        let metadata = AddNoteFixture.parameterMetadata

        let title = try! #require(metadata.first { $0.name == "title" })
        #expect(title.type == .string)
        #expect(title.required == true)
        #expect(title.description == "The note title")
        #expect(title.short == "t")
        #expect(title.aliases == ["name"])

        let body = try! #require(metadata.first { $0.name == "body" })
        #expect(body.type == .string)
        #expect(body.required == false)
        #expect(body.description == "Markdown body of the note.")

        let tags = try! #require(metadata.first { $0.name == "tags" })
        #expect(tags.type == .array(of: .string))
        #expect(tags.required == false)
        #expect(tags.description == "Tags to attach")
    }

    @Test func macroSynthesizedConformanceDispatchesThroughAnyOperation() async throws {
        let anyOp = AnyOperation(AddNoteFixture.self)
        let content = GeneratedContent(properties: ["title": "Groceries", "tags": ["errands", "home"]])
        let context = NotesFixtureContext()

        let json = try await anyOp.run(content, context)

        #expect(json == "{\"tagCount\":2,\"title\":\"Groceries\"}")
    }

    // MARK: - CLI-facing metadata

    @Test func macroSynthesizedConformanceCapturesItsDefinitionType() {
        let anyOp = AnyOperation(AddNoteFixture.self)

        #expect(ObjectIdentifier(anyOp.definitionType) == ObjectIdentifier(AddNoteFixture.self))
    }

    @Test func macroSynthesizedConformanceExposesItsGeneratedCommandType() throws {
        let anyOp = AnyOperation(AddNoteFixture.self)
        let commandType = try #require(anyOp.commandType)

        #expect(ObjectIdentifier(commandType) == ObjectIdentifier(AddNoteFixture.Command.self))
    }

    @Test func macroSynthesizedCLICommandTypealiasMatchesTheNestedCommand() {
        #expect(ObjectIdentifier(AddNoteFixture.CLICommand.self) == ObjectIdentifier(AddNoteFixture.Command.self))
    }
}
