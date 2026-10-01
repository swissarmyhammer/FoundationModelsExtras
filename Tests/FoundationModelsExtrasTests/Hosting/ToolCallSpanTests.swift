@testable import FoundationModelsExtras
import InMemoryTracing
import Logging
import MetricsTestKit
import TelemetryTestSupport
import Testing
import Tracing
import ULID

/// ``ToolCallSpan`` opens one span for each tool call, with the identity of
/// the call on it, writes one "enter" log record, and records one count and
/// one duration for each outcome.
@Suite("ToolCallSpan: one span, one enter record and the tool-call metrics for each tool call")
struct ToolCallSpanTests {
    /// The shared fixtures of the runner suites.
    private typealias Fixtures = MountFixtures

    /// The tool name that each test call uses.
    private static let toolName = "search"

    /// The value that the body of a test call gives back.
    private static let bodyValue = 7

    /// The count that one tool call adds to its counter.
    private static let oneCall: Int64 = 1

    /// The count of metrics that one tool call makes: one counter and one
    /// timer.
    private static let metricsOfOneCall = 2

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
        #expect(span.operationName == ExtrasTelemetry.SpanName.tool)
        #expect(span.kind == .internal)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.toolName) == .string(Self.toolName))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.sessionID) == .string(sessionID.description))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.runKind) == .string("background"))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.outcome) == nil)
        #expect(span.errors.isEmpty)
    }

    @Test("each call writes one enter log record with the tool name and the session")
    func eachCallWritesOneEnterRecord() async throws {
        let sessionID = ULID()

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await ToolCallSpan.withSpan(
                tracer: nil, toolName: Self.toolName, sessionID: sessionID, runKind: .foreground
            ) { _ in }
            return context
        }

        let record = try #require(context.logRecords.first)
        #expect(context.logRecords.count == 1)
        #expect(record.level == TracedCall.enterLevel)
        #expect("\(record.message)" == ExtrasTelemetry.EnterRecord.message(forSpanNamed: ExtrasTelemetry.SpanName.tool))
        #expect(record.metadata[ExtrasTelemetry.LogMetadataKey.toolName] == .string(Self.toolName))
        #expect(record.metadata[ExtrasTelemetry.LogMetadataKey.sessionID] == .string(sessionID.description))
        #expect(context.spans.count == 1)
    }

    @Test("record(outcome:on:) writes the outcome onto the span, and records one count and one duration")
    func recordWritesTheOutcomeAndTheMetrics() async throws {
        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await ToolCallSpan.withSpan(
                tracer: nil, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
            ) { call in
                ToolCallSpan.record(outcome: .timedOut, on: call)
            }
            return context
        }

        let span = try #require(context.spans.first)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.runKind) == .string("foreground"))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.outcome) == .string(OperationOutcome.timedOut.rawValue))
        try Self.expectOneCall(in: context, toolName: Self.toolName, outcome: .timedOut)
    }

    @Test("an error of the body gives the span the error status and error.type, no recorded error, and is thrown again")
    func anErrorSetsTheErrorStatusAndIsThrown() async throws {
        let tracer = InMemoryTracer()

        await #expect(throws: Boom.self) {
            try await ToolCallSpan.withSpan(
                tracer: tracer, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
            ) { _ in throw Boom() }
        }

        let span = try #require(tracer.finishedSpans.first)
        #expect(span.errors.isEmpty)
        #expect(span.status == SpanStatus(code: .error))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.errorType) == .string(String(reflecting: Boom.self)))
    }

    @Test("a run-to-completion call that succeeds gives one count and one duration of success")
    func aSucceededCallGivesItsMetrics() async throws {
        let tool = Fixtures.FastTool()
        let harness = Fixtures.runToCompletionHarness(wrapping: tool)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
            return context
        }

        try Self.expectOneCall(in: context, toolName: tool.name, outcome: .succeeded)
    }

    @Test("a run-to-completion call that fails gives one count and one duration of failure")
    func aFailedCallGivesItsMetrics() async throws {
        let tool = Fixtures.ThrowingTool()
        let harness = Fixtures.runToCompletionHarness(wrapping: tool)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await #expect(throws: Fixtures.FixtureError.self) {
                _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
            }
            return context
        }

        try Self.expectOneCall(in: context, toolName: tool.name, outcome: .failed)
    }

    @Test("a background call gives one count and one duration of its start")
    func aBackgroundStartGivesItsMetrics() async throws {
        let tool = Fixtures.FastTool()
        let harness = Fixtures.backgroundHarness(wrapping: tool)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
            return context
        }

        let span = try #require(context.spans.first)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.runKind) == .string("background"))
        try Self.expectOneCall(in: context, toolName: tool.name, outcome: .succeeded)
    }

    @Test("the tool span carries no tool argument and no tool output")
    func theToolSpanCarriesNoToolContent() async throws {
        let argument = "tool-argument-4d1f"
        let output = "tool-output-7b3a"

        let context = try await TelemetryCapture.run(forbidding: [argument, output]) { context in
            let value = try await ToolCallSpan.withSpan(
                tracer: context.tracer, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
            ) { call in
                ToolCallSpan.record(outcome: .succeeded, on: call)
                return "\(output) for \(argument)"
            }
            #expect(value.contains(output))
            return context
        }

        // A capture that recorded nothing would pass with no issue, thus the
        // test states what the capture measured.
        let span = try #require(context.spans.first)
        #expect(context.spans.count == 1)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.outcome) == .string(OperationOutcome.succeeded.rawValue))
    }

    @Test("a bound call of a tool whose output is not String gives one count and one duration of success")
    func aBoundCallGivesItsMetrics() async throws {
        let tool = Fixtures.NonStringOutputTool()
        let bound = ContextBindingTool(
            wrapping: tool, site: Fixtures.site(runPlane: RunPlane(), sink: Fixtures.RecordingSink()))

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await bound.call(arguments: MountArguments(value: "x"))
            return context
        }

        try Self.expectOneCall(in: context, toolName: tool.name, outcome: .succeeded)
    }

    /// Expects that the capture holds the telemetry of one tool call: one
    /// span, one "enter" log record, one count on the counter and one
    /// duration on the timer. Each metric has the tool name and the outcome
    /// as its only dimensions.
    ///
    /// - Parameters:
    ///   - context: The capture of the call.
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended.
    /// - Throws: When the capture has no such counter or timer.
    private static func expectOneCall(
        in context: TelemetryCapture.Context,
        toolName: String,
        outcome: OperationOutcome
    ) throws {
        let dimensions = [
            (ExtrasTelemetry.AttributeKey.toolName, toolName),
            (ExtrasTelemetry.AttributeKey.outcome, outcome.rawValue),
        ]
        let counter = try context.metricsFactory.expectCounter(ExtrasTelemetry.MetricName.toolCalls, dimensions)
        let timer = try context.metricsFactory.expectTimer(ExtrasTelemetry.MetricName.toolDuration, dimensions)
        #expect(counter.values == [oneCall])
        #expect(timer.values.count == 1)
        #expect(context.metricRecords.count == metricsOfOneCall)
        #expect(context.spans.map(\.operationName) == [ExtrasTelemetry.SpanName.tool])
        #expect(context.logRecords.map { "\($0.message)" } == [
            ExtrasTelemetry.EnterRecord.message(forSpanNamed: ExtrasTelemetry.SpanName.tool),
        ])
    }
}
