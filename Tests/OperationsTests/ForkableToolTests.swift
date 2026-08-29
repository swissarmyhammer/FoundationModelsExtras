import Foundation
import FoundationModels
import Testing

@testable import Operations

/// A minimal `Tool` used only to prove `ForkableTool`'s blanket default —
/// conforms to `ForkableTool` without implementing `forked()` itself,
/// relying entirely on the protocol extension's `{ self }` default.
private struct BareToolFixture: Tool, ForkableTool, Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    init(name: String = "bare", description: String = "A bare tool with no forked() override") throws {
        self.name = name
        self.description = description
        self.parameters = try GenerationSchema(
            root: DynamicGenerationSchema(name: name, description: description, properties: []),
            dependencies: []
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        "bare-output"
    }
}

/// A `Tool` that deliberately does not conform to `ForkableTool`, standing
/// in for a plain tool in the mixed `[any Tool]` list test — pass through
/// shared, unchanged.
private struct NonForkableToolFixture: Tool, Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name = "plain-fork"
    let description = "Does not conform to ForkableTool"
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

/// Reference-typed state shared by an `OperationTool`'s `context` across
/// `forked()` copies whenever `Context` does not itself conform to
/// `ForkableContext` — proving the fallback branch of `OperationTool`'s
/// `forked()` still shares underlying state, not just passes a stale copy.
private actor SharedCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

/// A `Context` with no `ForkableContext` conformance, pairing with
/// `BumpCounterToolFixture` to prove `OperationTool.forked()`'s fallback
/// (`context` shared unchanged) still shares reference-typed state.
private struct CounterContext: Sendable {
    let counter: SharedCounter
}

/// JSON-encodable result produced by `BumpCounterToolFixture.execute(in:)`.
private struct BumpOutput: Encodable, Sendable, Equatable {
    let value: Int
}

/// `bump counter` fixture: increments its context's shared counter and
/// reports the new value.
private struct BumpCounterToolFixture: OperationDefinition {
    typealias Context = CounterContext
    typealias Output = BumpOutput

    static let verb = "bump"
    static let noun = "counter"
    static let operationDescription = "Increments the shared counter and reports its new value"
    static let parameterMetadata: [ParamMeta] = []

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: BumpCounterToolFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [:])
    }

    func execute(in context: CounterContext) async throws -> BumpOutput {
        BumpOutput(value: await context.counter.increment())
    }
}

/// A `Context` conforming to `ForkableContext` whose custom `forked()` marks
/// every fork by incrementing `generation` — proves a `ForkableContext`
/// conformance is consulted by `OperationTool.forked()` rather than falling
/// back to a plain, unchanged copy.
private struct MarkingForkContext: Sendable, ForkableContext {
    let generation: Int

    func forked() -> MarkingForkContext {
        MarkingForkContext(generation: generation + 1)
    }
}

/// JSON-encodable result produced by `ReportGenerationToolFixture.execute(in:)`.
private struct GenerationOutput: Encodable, Sendable, Equatable {
    let generation: Int
}

/// `report generation` fixture: reports its context's `generation`, marked
/// by `MarkingForkContext.forked()` on every fork.
private struct ReportGenerationToolFixture: OperationDefinition {
    typealias Context = MarkingForkContext
    typealias Output = GenerationOutput

    static let verb = "report"
    static let noun = "generation"
    static let operationDescription = "Reports the context's generation"
    static let parameterMetadata: [ParamMeta] = []

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: ReportGenerationToolFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [:])
    }

    func execute(in context: MarkingForkContext) async throws -> GenerationOutput {
        GenerationOutput(generation: context.generation)
    }
}

@Suite struct ForkableToolTests {

    // MARK: - Blanket default: `func forked() -> any Tool { self }`

    @Test func forkableToolBlanketDefaultReturnsAFunctionallyEquivalentCopy() async throws {
        let tool = try BareToolFixture()

        let forked = tool.forked()

        guard let forkedBare = forked as? BareToolFixture else {
            Issue.record("forked() did not return a BareToolFixture")
            return
        }
        #expect(forkedBare.name == tool.name)
        #expect(forkedBare.description == tool.description)
        let output = try await forkedBare.call(arguments: GeneratedContent(properties: [:]))
        #expect(output == "bare-output")
    }

    // MARK: - OperationTool conforms to ForkableTool unconditionally

    @Test func fusedOperationToolSatisfiesForkableToolConformance() throws {
        let tool = try OperationTool(
            name: "gen",
            description: "Generation operations",
            context: MarkingForkContext(generation: 0),
            operations: [AnyOperation(ReportGenerationToolFixture.self)]
        )
        // Erased to `any Tool` first, matching how a host actually discovers
        // this conformance from its `[any Tool]` list — casting the
        // concrete `OperationTool<MarkingForkContext>` directly is a
        // statically-known-successful cast the compiler warns about.
        let erasedTool: any Tool = tool

        #expect(erasedTool as? any ForkableTool != nil)
    }

    // MARK: - No ForkableContext conformance: shared, unchanged, but still shares reference-typed state

    @Test func forkedToolWithoutForkableContextSharesUnderlyingReferenceTypedContextState() async throws {
        let counter = SharedCounter()
        let tool = try OperationTool(
            name: "counters",
            description: "Counter operations",
            context: CounterContext(counter: counter),
            operations: [AnyOperation(BumpCounterToolFixture.self)]
        )

        guard let forkedTool = tool.forked() as? OperationTool<CounterContext> else {
            Issue.record("forked() did not return an OperationTool<CounterContext>")
            return
        }

        let firstJSON = try await tool.call(arguments: GeneratedContent(properties: ["op": "bump counter"]))
        let secondJSON = try await forkedTool.call(arguments: GeneratedContent(properties: ["op": "bump counter"]))

        #expect(firstJSON.contains("\"value\":1"))
        #expect(secondJSON.contains("\"value\":2"))
    }

    // MARK: - ForkableContext conformance is consulted

    @Test func forkedToolWithForkableContextConsultsItsCustomForkedImplementation() async throws {
        let tool = try OperationTool(
            name: "gen",
            description: "Generation operations",
            context: MarkingForkContext(generation: 0),
            operations: [AnyOperation(ReportGenerationToolFixture.self)]
        )

        guard let forkedTool = tool.forked() as? OperationTool<MarkingForkContext> else {
            Issue.record("forked() did not return an OperationTool<MarkingForkContext>")
            return
        }

        let originalJSON = try await tool.call(arguments: GeneratedContent(properties: ["op": "report generation"]))
        let forkedJSON = try await forkedTool.call(arguments: GeneratedContent(properties: ["op": "report generation"]))

        #expect(originalJSON.contains("\"generation\":0"))
        #expect(forkedJSON.contains("\"generation\":1"))
    }

    // MARK: - Host mapping over a mixed [any Tool] list

    @Test func hostMappingOverAMixedAnyToolListForksOnlyForkableToolsIntoIndependentCopies() async throws {
        let counter = SharedCounter()
        let forkableTool = try OperationTool(
            name: "counters",
            description: "Counter operations",
            context: CounterContext(counter: counter),
            operations: [AnyOperation(BumpCounterToolFixture.self)]
        )
        let plainTool = try NonForkableToolFixture()
        let tools: [any Tool] = [plainTool, forkableTool]

        let forkedTools = tools.map { tool in
            (tool as? any ForkableTool)?.forked() ?? tool
        }

        #expect(forkedTools.count == 2)
        #expect(plainTool as? any ForkableTool == nil)

        guard let passthroughPlain = forkedTools[0] as? NonForkableToolFixture else {
            Issue.record("Non-conforming tool did not pass through as a NonForkableToolFixture")
            return
        }
        let plainOutput = try await passthroughPlain.call(arguments: GeneratedContent(properties: [:]))
        #expect(plainOutput == "plain-output")

        guard let forkedCounterTool = forkedTools[1] as? OperationTool<CounterContext> else {
            Issue.record("Forkable tool did not yield an OperationTool<CounterContext> copy")
            return
        }
        let originalJSON = try await forkableTool.call(arguments: GeneratedContent(properties: ["op": "bump counter"]))
        let forkedJSON = try await forkedCounterTool.call(arguments: GeneratedContent(properties: ["op": "bump counter"]))
        #expect(originalJSON.contains("\"value\":1"))
        #expect(forkedJSON.contains("\"value\":2"))
    }
}
