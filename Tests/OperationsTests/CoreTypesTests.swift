import FoundationModels
import Testing

@testable import Operations

/// Context passed to `FixtureOperation.execute(in:)`.
///
/// `shouldFail` lets a single test fixture exercise both the happy path and
/// the execution-throws path without needing two operation types.
private struct FixtureContext: Sendable {
    var shouldFail: Bool = false
}

/// JSON-encodable result produced by `FixtureOperation.execute(in:)`.
private struct FixtureOutput: Encodable, Sendable, Equatable {
    let echoed: String
    let length: Int
}

/// Error thrown by `FixtureOperation.execute(in:)` when `FixtureContext.shouldFail` is set.
private struct FixtureExecutionError: Error {}

/// Error thrown by `FailingEncodeOutput.encode(to:)`, always.
private struct FixtureEncodingError: Error {}

/// `Encodable` conformance that always throws, to exercise `AnyOperation.run`'s
/// output-encoding failure path.
private struct FailingEncodeOutput: Encodable, Sendable {
    func encode(to encoder: Encoder) throws {
        throw FixtureEncodingError()
    }
}

/// A hand-conformed `OperationDefinition` whose `Output` always fails to
/// JSON-encode, proving `AnyOperation.run` surfaces
/// `OperationError.encodingFailed` (not `.decodingFailed`) for that failure
/// mode.
private struct FailingEncodeOperation: OperationDefinition {
    typealias Context = FixtureContext
    typealias Output = FailingEncodeOutput

    static let verb = "boom"
    static let noun = "encode"
    static let operationDescription = "Always fails to JSON-encode its output"
    static let parameterMetadata: [ParamMeta] = []

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: FailingEncodeOperation.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [:])
    }

    func execute(in context: FixtureContext) async throws -> FailingEncodeOutput {
        FailingEncodeOutput()
    }
}

/// A hand-conformed `OperationDefinition` — no `@Operation`/`@Generable` macro
/// involved — proving the manual escape hatch plan.md calls out: conforming
/// directly to `OperationDefinition` (and, in turn, `Generable`) is always
/// possible without macro sugar.
private struct FixtureOperation: OperationDefinition {
    typealias Context = FixtureContext
    typealias Output = FixtureOutput

    var message: String

    static let verb = "echo"
    static let noun = "message"
    static let operationDescription = "Echoes a message back with its length"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "message", type: .string, required: true, description: "The message to echo")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: FixtureOperation.self,
            description: operationDescription,
            properties: [
                GenerationSchema.Property(name: "message", description: "The message to echo", type: String.self)
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        message = try content.value(String.self, forProperty: "message")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["message": message])
    }

    func execute(in context: FixtureContext) async throws -> FixtureOutput {
        if context.shouldFail {
            throw FixtureExecutionError()
        }
        return FixtureOutput(echoed: message, length: message.count)
    }
}

@Suite struct CoreTypesTests {

    // MARK: - ParamMeta

    @Test func paramMetaConstructionStoresAllFields() {
        let meta = ParamMeta(
            name: "tags",
            type: .array(of: .string),
            required: false,
            description: "Tags to attach",
            short: "t",
            aliases: ["labels"],
            allowedValues: ["a", "b"]
        )

        #expect(meta.name == "tags")
        #expect(meta.type == .array(of: .string))
        #expect(meta.required == false)
        #expect(meta.description == "Tags to attach")
        #expect(meta.short == "t")
        #expect(meta.aliases == ["labels"])
        #expect(meta.allowedValues == ["a", "b"])
    }

    @Test func paramMetaDefaultsShortAliasesAllowedValues() {
        let meta = ParamMeta(name: "title", type: .string, required: true, description: "The title")

        #expect(meta.short == nil)
        #expect(meta.aliases == [])
        #expect(meta.allowedValues == nil)
    }

    // MARK: - opString default

    @Test func opStringDefaultRendersVerbSpaceNoun() {
        #expect(FixtureOperation.opString == "echo message")
    }

    // MARK: - AnyOperation

    @Test func anyOperationCapturesMetadataFromOperationDefinition() {
        let anyOp = AnyOperation(FixtureOperation.self)

        #expect(anyOp.verb == "echo")
        #expect(anyOp.noun == "message")
        #expect(anyOp.description == "Echoes a message back with its length")
        #expect(anyOp.parameters == FixtureOperation.parameterMetadata)
    }

    // MARK: - CLI-facing metadata

    @Test func anyOperationCapturesItsDefinitionType() {
        let anyOp = AnyOperation(FixtureOperation.self)

        #expect(ObjectIdentifier(anyOp.definitionType) == ObjectIdentifier(FixtureOperation.self))
    }

    @Test func anyOperationCommandTypeIsNilForAHandConformedOperation() {
        // `FixtureOperation` conforms to `OperationDefinition` directly (no
        // `@Operation` macro, no nested `Command`), proving the manual escape
        // hatch has no CLI leaf to offer the driver.
        let anyOp = AnyOperation(FixtureOperation.self)

        #expect(anyOp.commandType == nil)
    }

    @Test func anyOperationRunHappyPathReturnsDeterministicSortedKeyJSON() async throws {
        let anyOp = AnyOperation(FixtureOperation.self)
        let content = GeneratedContent(properties: ["message": "hi"])
        let context = FixtureContext(shouldFail: false)

        let json = try await anyOp.run(content, context)

        #expect(json == "{\"echoed\":\"hi\",\"length\":2}")
    }

    @Test func anyOperationRunExecuteThrowsSurfacesOperationErrorExecutionFailed() async throws {
        let anyOp = AnyOperation(FixtureOperation.self)
        let content = GeneratedContent(properties: ["message": "hi"])
        let context = FixtureContext(shouldFail: true)

        do {
            _ = try await anyOp.run(content, context)
            Issue.record("expected OperationError.executionFailed to be thrown")
        } catch let error as OperationError {
            #expect(error == .executionFailed)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func anyOperationRunDecodingFailureSurfacesOperationErrorDecodingFailed() async throws {
        let anyOp = AnyOperation(FixtureOperation.self)
        // Missing the required "message" property entirely — the hand-rolled
        // `FixtureOperation.init(_:)` throws when reading it back out.
        let content = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
        let context = FixtureContext(shouldFail: false)

        do {
            _ = try await anyOp.run(content, context)
            Issue.record("expected OperationError.decodingFailed to be thrown")
        } catch let error as OperationError {
            #expect(error == .decodingFailed)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func anyOperationRunOutputEncodingFailureSurfacesOperationErrorEncodingFailed() async throws {
        let anyOp = AnyOperation(FailingEncodeOperation.self)
        let content = GeneratedContent(properties: [:])
        let context = FixtureContext(shouldFail: false)

        do {
            _ = try await anyOp.run(content, context)
            Issue.record("expected OperationError.encodingFailed to be thrown")
        } catch let error as OperationError {
            #expect(error == .encodingFailed)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - OperationError.description

    @Test func operationErrorDecodingFailedDescriptionReturnsParameterParsingMessage() {
        #expect(OperationError.decodingFailed.description == "Could not parse the given parameter values for this operation.")
    }

    @Test func operationErrorEncodingFailedDescriptionReturnsResultEncodingMessage() {
        #expect(OperationError.encodingFailed.description == "Could not encode this operation's result.")
    }

    @Test func operationErrorExecutionFailedDescriptionReturnsExecutionFailureMessage() {
        #expect(OperationError.executionFailed.description == "This operation failed while executing.")
    }
}
