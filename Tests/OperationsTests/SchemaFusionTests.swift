import FoundationModels
import Foundation
import Testing

@testable import Operations

/// Shared `Context` for every schema-fusion fixture operation below.
///
/// Schema fusion only reads `AnyOperation` metadata (`verb`, `noun`,
/// `parameters`) — it never calls `execute(in:)` — so this context carries
/// no state.
private struct FusionFixtureContext: Sendable {}

/// Trivial `Output` shared by every schema-fusion fixture operation; never
/// produced, since these tests never call `execute(in:)`.
private struct FusionFixtureOutput: Encodable, Sendable {}

/// `add note` fixture: a required `title` and an optional `tags` array,
/// exercising the string and `array(of: .string)` `ParamType` cases.
private struct FixtureAddNote: OperationDefinition {
    typealias Context = FusionFixtureContext
    typealias Output = FusionFixtureOutput

    static let verb = "add"
    static let noun = "note"
    static let operationDescription = "Create a new note"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "title", type: .string, required: true, description: "The note title"),
        ParamMeta(name: "tags", type: .array(of: .string), required: false, description: "Tags to attach"),
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: FixtureAddNote.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent { GeneratedContent(properties: [:]) }

    func execute(in context: FusionFixtureContext) async throws -> FusionFixtureOutput {
        FusionFixtureOutput()
    }
}

/// `get note` fixture: a required `id`, whose description must win the
/// first-description-wins collision against `FixtureDeleteNote`'s `id`.
private struct FixtureGetNote: OperationDefinition {
    typealias Context = FusionFixtureContext
    typealias Output = FusionFixtureOutput

    static let verb = "get"
    static let noun = "note"
    static let operationDescription = "Fetch a note by id"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The note id (first-seen)")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: FixtureGetNote.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent { GeneratedContent(properties: [:]) }

    func execute(in context: FusionFixtureContext) async throws -> FusionFixtureOutput {
        FusionFixtureOutput()
    }
}

/// `delete note` fixture: a required `id` whose description must lose the
/// collision, plus an optional `force` flag exercising the boolean
/// `ParamType` case.
private struct FixtureDeleteNote: OperationDefinition {
    typealias Context = FusionFixtureContext
    typealias Output = FusionFixtureOutput

    static let verb = "delete"
    static let noun = "note"
    static let operationDescription = "Delete a note by id"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "id", type: .string, required: true, description: "The note id (second-seen, must lose)"),
        ParamMeta(name: "force", type: .boolean, required: false, description: "Skip confirmation"),
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: FixtureDeleteNote.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent { GeneratedContent(properties: [:]) }

    func execute(in context: FusionFixtureContext) async throws -> FusionFixtureOutput {
        FusionFixtureOutput()
    }
}

/// `rate item` fixture: a required `score`, exercising the `.number`
/// (`Double`) `ParamType` case — otherwise unexercised by any other fixture
/// in this file.
private struct FixtureRateItem: OperationDefinition {
    typealias Context = FusionFixtureContext
    typealias Output = FusionFixtureOutput

    static let verb = "rate"
    static let noun = "item"
    static let operationDescription = "Rate an item"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "score", type: .number, required: true, description: "The rating, as a fractional score")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: FixtureRateItem.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent { GeneratedContent(properties: [:]) }

    func execute(in context: FusionFixtureContext) async throws -> FusionFixtureOutput {
        FusionFixtureOutput()
    }
}

/// A fixture operation that illegally declares a parameter literally named
/// `"op"`, proving fusion rejects the collision with a descriptive error.
private struct FixtureReservedOpLiteral: OperationDefinition {
    typealias Context = FusionFixtureContext
    typealias Output = FusionFixtureOutput

    static let verb = "bad"
    static let noun = "literal"
    static let operationDescription = "Illegally declares a literal op parameter"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "op", type: .string, required: false, description: "Collides with the discriminator")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: FixtureReservedOpLiteral.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent { GeneratedContent(properties: [:]) }

    func execute(in context: FusionFixtureContext) async throws -> FusionFixtureOutput {
        FusionFixtureOutput()
    }
}

/// A fixture operation whose reserved parameter name is spelled `"_OP"` —
/// proving the reserved-name check normalizes case and separators before
/// comparing, not just a literal `"op"`.
private struct FixtureReservedOpNormalized: OperationDefinition {
    typealias Context = FusionFixtureContext
    typealias Output = FusionFixtureOutput

    static let verb = "bad"
    static let noun = "normalized"
    static let operationDescription = "Illegally declares a normalized op parameter"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "_OP", type: .string, required: false, description: "Also collides, after normalization")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: FixtureReservedOpNormalized.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent { GeneratedContent(properties: [:]) }

    func execute(in context: FusionFixtureContext) async throws -> FusionFixtureOutput {
        FusionFixtureOutput()
    }
}

@Suite struct SchemaFusionTests {

    /// Fuses `operations`, encodes the resulting `GenerationSchema` to JSON,
    /// and decodes it back to a plain JSON object for structural assertions
    /// — never a byte-level snapshot of Apple's encoding.
    private func fusedJSONObject(
        _ operations: [AnyOperation<FusionFixtureContext>],
        name: String = "FusedFixture"
    ) throws -> [String: Any] {
        let schema = try SchemaFusion.fuse(operations, name: name)
        let data = try JSONEncoder().encode(schema)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private var threeOpFixture: [AnyOperation<FusionFixtureContext>] {
        [
            AnyOperation(FixtureAddNote.self),
            AnyOperation(FixtureGetNote.self),
            AnyOperation(FixtureDeleteNote.self),
        ]
    }

    // MARK: - op enum

    @Test func opEnumHasExactlyTheThreeOpStrings() throws {
        let object = try fusedJSONObject(threeOpFixture)
        let properties = try #require(object["properties"] as? [String: Any])
        let opSchema = try #require(properties["op"] as? [String: Any])
        let opEnum = try #require(opSchema["enum"] as? [String])

        #expect(Set(opEnum) == Set(["add note", "get note", "delete note"]))
        #expect(opEnum.count == 3)
    }

    // MARK: - optionality

    @Test func everyPropertyButOpIsOptional() throws {
        let object = try fusedJSONObject(threeOpFixture)
        let required = try #require(object["required"] as? [String])

        #expect(required == ["op"])
    }

    // MARK: - field union

    @Test func fieldUnionContainsEveryDeclaredParameterNameOnce() throws {
        let object = try fusedJSONObject(threeOpFixture)
        let properties = try #require(object["properties"] as? [String: Any])

        #expect(Set(properties.keys) == Set(["op", "title", "tags", "id", "force"]))
    }

    @Test func sharedFieldDedupsToFirstSeenDescription() throws {
        let object = try fusedJSONObject(threeOpFixture)
        let properties = try #require(object["properties"] as? [String: Any])
        let idSchema = try #require(properties["id"] as? [String: Any])

        #expect(idSchema["description"] as? String == "The note id (first-seen)")
    }

    // MARK: - deterministic order

    /// `FixtureAddNote` (op index 0) declares `title` before `tags`, but
    /// `"tags" < "title"` alphabetically — pinning the field union's order
    /// to (first-seen op index, then name) rather than raw declaration
    /// order, per the task's "fields sorted by first-seen op order then
    /// name" spec.
    @Test func propertyOrderIsOpFirstThenFirstSeenOpIndexThenName() throws {
        let object = try fusedJSONObject(threeOpFixture)
        let order = try #require(object["x-order"] as? [String])

        #expect(order == ["op", "tags", "title", "id", "force"])
    }

    @Test func sameInputArrayProducesByteIdenticalEncodingAcrossRuns() throws {
        let first = try SchemaFusion.fuse(threeOpFixture, name: "FusedFixture")
        let second = try SchemaFusion.fuse(threeOpFixture, name: "FusedFixture")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(first) == encoder.encode(second))
    }

    // MARK: - field types

    /// Exercises `dynamicSchema(for:)`'s `.number` case
    /// (`DynamicGenerationSchema(type: Double.self)`), otherwise untouched by
    /// any other fixture in this file: the fused schema must render a
    /// `Double`-typed field as a JSON Schema `number`.
    @Test func numberParameterIsRenderedAsNumberType() throws {
        let object = try fusedJSONObject([AnyOperation(FixtureRateItem.self)])
        let properties = try #require(object["properties"] as? [String: Any])
        let scoreSchema = try #require(properties["score"] as? [String: Any])

        #expect(scoreSchema["type"] as? String == "number")
    }

    // MARK: - reserved `op` parameter name

    @Test func fusionThrowsDescriptiveErrorOnLiteralReservedOpParameter() throws {
        let operations = [AnyOperation(FixtureReservedOpLiteral.self)]

        do {
            _ = try SchemaFusion.fuse(operations, name: "FusedFixture")
            Issue.record("expected SchemaFusionError.reservedParameterName to be thrown")
        } catch let error as SchemaFusionError {
            #expect(error == .reservedParameterName(opString: "bad literal", parameter: "op"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func fusionThrowsDescriptiveErrorOnNormalizedReservedOpParameter() throws {
        let operations = [AnyOperation(FixtureReservedOpNormalized.self)]

        do {
            _ = try SchemaFusion.fuse(operations, name: "FusedFixture")
            Issue.record("expected SchemaFusionError.reservedParameterName to be thrown")
        } catch let error as SchemaFusionError {
            #expect(error == .reservedParameterName(opString: "bad normalized", parameter: "_OP"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func reservedOpParameterErrorDescriptionIsDescriptive() {
        let error = SchemaFusionError.reservedParameterName(opString: "bad literal", parameter: "op")

        #expect(error.description.contains("op"))
        #expect(error.description.contains("bad literal"))
    }
}
