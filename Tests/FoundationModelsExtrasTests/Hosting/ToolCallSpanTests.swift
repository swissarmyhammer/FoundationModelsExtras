@testable import FoundationModelsExtras
import InMemoryTracing
import Testing
import Tracing
import ULID

/// ``ToolCallSpan`` opens one span for each tool call, with the identity of
/// the call on it.
@Suite("ToolCallSpan: one span for each tool call")
struct ToolCallSpanTests {
    /// The tool name that each test call uses.
    private static let toolName = "search"

    /// The value that the body of a test call gives back.
    private static let bodyValue = 7

    /// The error that a failing body throws.
    private struct Boom: Error {}

    @Test("the span carries the tool name, the session and the run kind, and the call gives back the body value")
    func theSpanCarriesTheCallIdentity() async throws {
        let tracer = InMemoryTracer()
        let sessionID = ULID()

        let value = try await ToolCallSpan.withSpan(
            tracer: tracer, toolName: Self.toolName, sessionID: sessionID, runKind: .background
        ) { _ in Self.bodyValue }

        let span = try #require(tracer.finishedSpans.first)
        #expect(value == Self.bodyValue)
        #expect(tracer.finishedSpans.count == 1)
        #expect(span.operationName == "FoundationModelsRouter.tool")
        #expect(span.kind == .internal)
        #expect(span.attributes.get("tool.name") == .string(Self.toolName))
        #expect(span.attributes.get("session.id") == .string(sessionID.description))
        #expect(span.attributes.get("tool.run_kind") == .string("background"))
        #expect(span.attributes.get("tool.outcome") == nil)
        #expect(span.errors.isEmpty)
    }

    @Test("record(outcome:on:) writes the outcome onto the span")
    func recordWritesTheOutcome() async throws {
        let tracer = InMemoryTracer()

        try await ToolCallSpan.withSpan(
            tracer: tracer, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
        ) { span in
            ToolCallSpan.record(outcome: .timedOut, on: span)
        }

        let span = try #require(tracer.finishedSpans.first)
        #expect(span.attributes.get("tool.run_kind") == .string("foreground"))
        #expect(span.attributes.get("tool.outcome") == .string(OperationOutcome.timedOut.rawValue))
    }

    @Test("an error of the body is recorded on the span and thrown again")
    func anErrorIsRecordedAndThrown() async throws {
        let tracer = InMemoryTracer()

        await #expect(throws: Boom.self) {
            try await ToolCallSpan.withSpan(
                tracer: tracer, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
            ) { _ in throw Boom() }
        }

        let span = try #require(tracer.finishedSpans.first)
        #expect(span.errors.count == 1)
    }
}
