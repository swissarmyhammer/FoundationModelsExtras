import Foundation
import FoundationModels
import Testing

@testable import Operations

/// Collects every event posted to it, for assertion. Stands in for a real
/// session host's outbox.
private actor FakeEventSinkActor: OperationEventSink {
    private(set) var events: [OperationEvent] = []

    func post(event: OperationEvent) async {
        events.append(event)
    }
}

/// Reference-typed state shared by every copy of `EmittingFixtureContext`
/// `connecting(_:)` produces, independent of its event route — proves
/// `connecting(_:)` copies keep sharing underlying state while each gets its
/// own route.
private actor SharedRunLog {
    private(set) var correlationIDs: [String] = []

    func record(_ correlationID: String) {
        correlationIDs.append(correlationID)
    }
}

/// A `Context` that opts into event emission by exposing an immutable
/// optional sink plus a pure `connecting(_:)` — the "opt-in context
/// protocol" `EventEmittingContext` describes.
private struct EmittingFixtureContext: EventEmittingContext {
    let operationEventSink: (any OperationEventSink)?
    let runLog: SharedRunLog

    init(operationEventSink: (any OperationEventSink)? = nil, runLog: SharedRunLog = SharedRunLog()) {
        self.operationEventSink = operationEventSink
        self.runLog = runLog
    }

    func connecting(_ sink: any OperationEventSink) -> EmittingFixtureContext {
        EmittingFixtureContext(operationEventSink: sink, runLog: runLog)
    }
}

/// JSON-encodable result produced by `EmitProgressToolFixture.execute(in:)`.
private struct EmittingOutput: Encodable, Sendable, Equatable {
    let done: Bool
}

/// `run job` fixture: posts a `.progress` then a `.completed` event through
/// its context's connected sink (a safe no-op when none is connected) while
/// executing, and records its `correlationID` into the context's shared run
/// log regardless — exercising posting and shared state together, from
/// inside `execute(in:)`, independent of dispatch.
private struct EmitProgressToolFixture: OperationDefinition {
    typealias Context = EmittingFixtureContext
    typealias Output = EmittingOutput

    var correlationID: String

    static let verb = "run"
    static let noun = "job"
    static let operationDescription = "Emits progress and completion events while running"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "correlationID", type: .string, required: true, description: "Correlates posted events")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: EmitProgressToolFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        correlationID = try content.value(String.self, forProperty: "correlationID")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["correlationID": correlationID])
    }

    func execute(in context: EmittingFixtureContext) async throws -> EmittingOutput {
        await context.operationEventSink?.post(
            event: OperationEvent(tool: "jobs", op: Self.opString, correlationID: correlationID, kind: .progress, detail: "{\"percent\":50}")
        )
        await context.operationEventSink?.post(
            event: OperationEvent(
                tool: "jobs", op: Self.opString, correlationID: correlationID, kind: .completed, detail: "{\"percent\":100}")
        )
        await context.runLog.record(correlationID)
        return EmittingOutput(done: true)
    }
}

/// A plain `Context` with no `EventEmittingContext` conformance, pairing
/// with `PlainToolFixture` to build a non-emitting `OperationTool` for the
/// mixed `[any Tool]` list test.
private struct PlainContext: Sendable {}

/// JSON-encodable result produced by `PlainToolFixture.execute(in:)`.
private struct PlainOutput: Encodable, Sendable, Equatable {
    let echoed: String
}

/// `echo plain` fixture: an ordinary operation over a `Context` that never
/// opts into event emission.
private struct PlainToolFixture: OperationDefinition {
    typealias Context = PlainContext
    typealias Output = PlainOutput

    var message: String

    static let verb = "echo"
    static let noun = "plain"
    static let operationDescription = "Echoes a message back, no event emission"
    static let parameterMetadata: [ParamMeta] = [
        ParamMeta(name: "message", type: .string, required: true, description: "The message to echo")
    ]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: PlainToolFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {
        message = try content.value(String.self, forProperty: "message")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["message": message])
    }

    func execute(in context: PlainContext) async throws -> PlainOutput {
        PlainOutput(echoed: message)
    }
}

@Suite struct EventEmittingToolTests {

    // MARK: - OperationEvent: Codable round trip and wire shape

    @Test func operationEventCodableRoundTripPreservesAllFields() throws {
        let event = OperationEvent(
            tool: "jobs", op: "run job", correlationID: "cid-1", kind: .completed, detail: "{\"percent\":100}")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func operationEventEncodesKindAsLowercaseRawStringInJSON() throws {
        let event = OperationEvent(tool: "jobs", op: "run job", correlationID: "cid-1", kind: .progress, detail: "{}")

        let data = try JSONEncoder().encode(event)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"kind\":\"progress\""))
    }

    // MARK: - OperationEvent.outcome: backward compatibility and round trip

    @Test func initDefaultsOutcomeToNilSoExistingCallSitesCompileUnchanged() {
        let event = OperationEvent(tool: "jobs", op: "run job", correlationID: "cid-1", kind: .progress, detail: "{}")

        #expect(event.outcome == nil)
    }

    @Test func decodingAPreviouslyRecordedEventWithNoOutcomeKeyDefaultsToNil() throws {
        // Simulates an `OperationEvent` recorded before `outcome` existed —
        // e.g. a Router-journaled `OperationEventSegment` already committed
        // to a transcript. `decodeIfPresent` must default to `nil` rather
        // than throwing `keyNotFound`.
        let json = """
            {"tool":"jobs","op":"run job","correlationID":"cid-1","kind":"completed","detail":"{\\"percent\\":100}"}
            """
        let data = Data(json.utf8)

        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)

        #expect(decoded.outcome == nil)
        #expect(decoded.kind == .completed)
    }

    @Test func codableRoundTripPreservesAPresentOutcome() throws {
        let event = OperationEvent(
            tool: "jobs", op: "run job", correlationID: "cid-1", kind: .completed, detail: "{}", outcome: .succeeded)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)

        #expect(decoded == event)
        #expect(decoded.outcome == .succeeded)
    }

    // MARK: - connecting(_:): route independence + shared context state

    @Test func connectingTwoSinksPostIndependentlyWhileSharingUnderlyingContextState() async throws {
        // "tool.connecting(sinkA) and tool.connecting(sinkB) post to their
        // own sinks independently; the original posts into the void; all
        // three share underlying reference-typed context state" — one test
        // proving both route independence and state sharing together.
        let runLog = SharedRunLog()
        let baseTool = try OperationTool(
            name: "jobs",
            description: "Job operations",
            context: EmittingFixtureContext(runLog: runLog),
            operations: [AnyOperation(EmitProgressToolFixture.self)]
        )
        let sinkA = FakeEventSinkActor()
        let sinkB = FakeEventSinkActor()

        guard let toolA = baseTool.connecting(sinkA) as? OperationTool<EmittingFixtureContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<EmittingFixtureContext>")
            return
        }
        guard let toolB = baseTool.connecting(sinkB) as? OperationTool<EmittingFixtureContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<EmittingFixtureContext>")
            return
        }

        _ = try await toolA.call(arguments: GeneratedContent(properties: ["op": "run job", "correlationID": "cid-a"]))
        _ = try await toolB.call(arguments: GeneratedContent(properties: ["op": "run job", "correlationID": "cid-b"]))
        _ = try await baseTool.call(arguments: GeneratedContent(properties: ["op": "run job", "correlationID": "cid-orig"]))

        let eventsA = await sinkA.events
        let eventsB = await sinkB.events
        #expect(eventsA.map(\.correlationID) == ["cid-a", "cid-a"])
        #expect(eventsB.map(\.correlationID) == ["cid-b", "cid-b"])

        // All three dispatches — toolA, toolB, and the un-connected
        // baseTool — recorded into the same shared run log, proving the
        // reference-typed context state is shared across every copy.
        let recordedIDs = await runLog.correlationIDs
        #expect(recordedIDs == ["cid-a", "cid-b", "cid-orig"])
    }

    @Test func operationWithNoConnectedSinkDispatchesNormallyWithoutErrorOrRetention() async throws {
        let tool = try OperationTool(
            name: "jobs",
            description: "Job operations",
            context: EmittingFixtureContext(),
            operations: [AnyOperation(EmitProgressToolFixture.self)]
        )
        let arguments = GeneratedContent(properties: ["op": "run job", "correlationID": "cid-2"])

        let json = try await tool.call(arguments: arguments)

        #expect(json.contains("\"done\":true"))
    }

    // MARK: - Host mapping over a mixed [any Tool] list

    @Test func hostMappingOverAMixedAnyToolListConnectsOnlyEmittingToolsPureCopies() async throws {
        let emittingTool = try OperationTool(
            name: "jobs",
            description: "Job operations",
            context: EmittingFixtureContext(),
            operations: [AnyOperation(EmitProgressToolFixture.self)]
        )
        let plainTool = try OperationTool(
            name: "plain",
            description: "Plain operations",
            context: PlainContext(),
            operations: [AnyOperation(PlainToolFixture.self)]
        )
        let tools: [any Tool] = [plainTool, emittingTool]
        let sink = FakeEventSinkActor()

        let connectedTools = tools.map { tool in
            (tool as? any EventEmittingTool)?.connecting(sink) ?? tool
        }

        #expect(connectedTools.count == 2)
        #expect(plainTool as? any EventEmittingTool == nil)

        guard let passthroughPlain = connectedTools[0] as? OperationTool<PlainContext> else {
            Issue.record("Non-conforming tool did not pass through as an OperationTool<PlainContext>")
            return
        }
        let plainResult = try await passthroughPlain.call(
            arguments: GeneratedContent(properties: ["op": "echo plain", "message": "hi"]))
        #expect(plainResult.contains("\"echoed\":\"hi\""))

        guard let connectedEmitting = connectedTools[1] as? OperationTool<EmittingFixtureContext> else {
            Issue.record("Emitting tool's connecting(_:) did not return an OperationTool<EmittingFixtureContext>")
            return
        }
        let arguments = GeneratedContent(properties: ["op": "run job", "correlationID": "cid-1"])
        _ = try await connectedEmitting.call(arguments: arguments)

        let events = await sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.allSatisfy { $0.tool == "jobs" && $0.op == "run job" && $0.correlationID == "cid-1" })
    }
}
