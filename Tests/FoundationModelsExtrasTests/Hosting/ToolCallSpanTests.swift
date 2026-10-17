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

    /// The wire text of a tool outcome that this package does not know. No
    /// place of the telemetry may carry it.
    private static let unknownOutcome = "unknown-outcome-3c8e"

    /// The largest difference that a test accepts between the duration on the
    /// timer and the duration of the span of one call. The two come from the
    /// same call, thus they differ only by the few steps between the two
    /// records.
    private static let sameIntervalTolerance = Duration.milliseconds(100)

    /// The settle period of a background call whose run must settle inside
    /// it. The run plane of the call waits on a manual clock, and the test
    /// moves the clock by this full period only after the run settled.
    private static let inlineSettleGrace = Fixtures.generousInterval

    /// The settle period of a background call whose run continues after it.
    /// The test moves the manual clock of the run plane by this full period.
    private static let pendingSettleGrace = Fixtures.shortInterval

    /// The argument of a background call in the content-safety test. The tool
    /// output and the terminal detail of the call hold it. No place of the
    /// telemetry may carry it.
    private static let backgroundContent = "background-content-5e2c"

    /// The error that a failing body throws.
    private struct Boom: Error {}

    /// A sink that holds each report post until the test opens ``release``.
    /// It keeps no event.
    private actor HeldReportSink: OperationEventSink, ToolCallReportSink {
        /// Opens when a report post comes.
        nonisolated let arrived = RunLatch()

        /// The gate that each report post waits for.
        nonisolated let release = RunLatch()

        /// Drops `event`. The test reads the telemetry only.
        func post(event: OperationEvent) {}

        /// Opens ``arrived``, then holds the post of `report` until
        /// ``release`` opens.
        func post(report: ToolCallReport) async {
            arrived.open()
            await release.waitUntilOpen()
        }
    }

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

    @Test("a terminal event with no outcome records one count and one duration of lost")
    func aTerminalEventWithNoOutcomeRecordsOneCall() async throws {
        let terminal = OperationEvent.terminal(
            tool: Self.toolName, op: Self.toolName, token: ULID().description, outcome: nil)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await ToolCallSpan.withSpan(
                tracer: nil, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
            ) { call in
                ToolCallSpan.record(outcomeOf: terminal, on: call)
            }
            return context
        }

        let span = try #require(context.spans.first)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.outcome) == .string(QueueOutcome.lost.rawValue))
        try Self.expectOneCall(in: context, toolName: Self.toolName, outcome: .lost)
    }

    @Test("an outcome that this package does not know gives tool.outcome=other on the span and on each metric")
    func anUnknownOutcomeGivesOtherOnTheSpanAndTheMetrics() async throws {
        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await ToolCallSpan.withSpan(
                tracer: nil, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
            ) { call in
                ToolCallSpan.record(outcome: .other(Self.unknownOutcome), on: call)
            }
            return context
        }

        let span = try #require(context.spans.first)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.outcome) == .string(QueueOutcome.other.rawValue))
        try Self.expectOneCall(in: context, toolName: Self.toolName, outcomeValue: QueueOutcome.other.rawValue)
    }

    @Test("the text of an outcome that this package does not know goes to no place of the telemetry")
    func theTextOfAnUnknownOutcomeDoesNotLeak() async throws {
        let context = try await TelemetryCapture.run(forbidding: [Self.unknownOutcome]) { context in
            try await ToolCallSpan.withSpan(
                tracer: context.tracer, toolName: Self.toolName, sessionID: ULID(), runKind: .foreground
            ) { call in
                ToolCallSpan.record(outcome: .other(Self.unknownOutcome), on: call)
            }
            return context
        }

        // A capture that recorded nothing would pass with no issue, thus the
        // test states what the capture measured.
        #expect(context.spans.count == 1)
        #expect(context.metricRecords.count == Self.metricsOfOneCall)
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

        // The failed call sends its terminal event upstream, thus the capture
        // also holds the queue metrics of that delivery.
        try Self.expectOneCall(
            in: context, toolName: tool.name, outcome: .failed,
            metricLabels: Fixtures.metricLabelsOfACallThatSendsItsTerminal)
        let span = try #require(context.spans.first)
        #expect(span.status == SpanStatus(code: .error))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.errorType)
                == .string(String(reflecting: Fixtures.FixtureError.self)))
    }

    @Test("a run-to-completion call that times out records timed_out with no error status, and throws the timeout")
    func aTimedOutCallIsNotAnError() async throws {
        let tool = Fixtures.SleepingTool()
        let clock = ManualRunClock()
        let harness = Fixtures.runToCompletionHarness(
            wrapping: tool, timeout: Fixtures.shortInterval, runPlane: RunPlane(clock: clock))
        let timeout = ToolMountError.timedOut(tool: tool.name, timeoutSeconds: Fixtures.shortInterval)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let mounted = harness.mounted
            let calling = Task { try await mounted.call(arguments: MountArguments(value: "x")) }
            await #expect(throws: timeout) {
                _ = try await clock.elapse(Fixtures.shortInterval, endingWait: calling)
            }
            return context
        }

        let span = try #require(context.spans.first)
        #expect(span.status == nil)
        #expect(span.errors.isEmpty)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.errorType) == nil)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.outcome) == .string(QueueOutcome.timedOut.rawValue))
        // The timed-out call sends its terminal event upstream, thus the
        // capture also holds the queue metrics of that delivery.
        try Self.expectOneCall(
            in: context, toolName: tool.name, outcome: .timedOut,
            metricLabels: Fixtures.metricLabelsOfACallThatSendsItsTerminal)
    }

    @Test("a background call that answers at once with the pending envelope gives one count and one duration of success")
    func aBackgroundStartGivesItsMetrics() async throws {
        let tool = Fixtures.FastTool()
        let harness = Fixtures.backgroundHarness(wrapping: tool)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
            // The run continues after the call. Its body ends here, thus the
            // capture holds each record of the run when the test reads it.
            await harness.runPlane.joinRunBodies()
            return context
        }

        let span = try #require(context.spans.first { $0.operationName == ExtrasTelemetry.SpanName.tool })
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.runKind) == .string("background"))
        try Self.expectToolCallMetrics(in: context, toolName: tool.name, outcomeValue: OperationOutcome.succeeded.rawValue)
        #expect(context.spans.map(\.operationName).sorted() == Fixtures.spanNamesOfASettledBackgroundCall)
        #expect(context.logRecords.map { "\($0.message)" }.sorted() == Fixtures.spanNamesOfASettledBackgroundCall.map {
            ExtrasTelemetry.EnterRecord.message(forSpanNamed: $0)
        })
        #expect(context.metricRecords.map(\.label) == Fixtures.metricLabelsOfASettledBackgroundCall)
    }

    @Test("a background run that succeeds inside the settle period records succeeded and tool.settled_inline=true")
    func aBackgroundRunThatSucceedsInlineRecordsSucceeded() async throws {
        let tool = Fixtures.FastTool()
        let plane = await ManualSettlePlane.make()
        let harness = Fixtures.backgroundHarness(
            wrapping: tool, inlineSettleGrace: Self.inlineSettleGrace, runPlane: plane.runPlane)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let mounted = harness.mounted
            _ = try await plane.answer(settlingWithin: Self.inlineSettleGrace) {
                try await mounted.call(arguments: MountArguments(value: "x"))
            }
            await harness.runPlane.joinRunBodies()
            return context
        }

        let span = try Self.expectBackgroundCall(
            in: context, toolName: tool.name, outcomeValue: QueueOutcome.succeeded.rawValue, isSettledInline: true)
        #expect(span.status == nil)
    }

    @Test("a background call on a site with a session tracer records the tool span and the run span on that tracer")
    func aBackgroundCallRecordsBothSpansOnTheSessionTracer() async throws {
        // The test binds no task-local tracer, thus only the tracer of the
        // site can receive the two spans.
        let tracer = W3CInMemoryTracer()
        let plane = await ManualSettlePlane.make()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.FastTool(), inlineSettleGrace: Self.inlineSettleGrace, tracer: tracer,
            runPlane: plane.runPlane)

        let mounted = harness.mounted
        _ = try await plane.answer(settlingWithin: Self.inlineSettleGrace) {
            try await mounted.call(arguments: MountArguments(value: "x"))
        }
        await harness.runPlane.joinRunBodies()

        #expect(tracer.finishedSpans.map(\.operationName).sorted() == Fixtures.spanNamesOfASettledBackgroundCall)
    }

    @Test("a background run that fails inside the settle period records one count and one duration of failed, and throws the error")
    func aBackgroundRunThatFailsInlineRecordsFailed() async throws {
        let tool = Fixtures.ThrowingTool()
        let plane = await ManualSettlePlane.make()
        let harness = Fixtures.backgroundHarness(
            wrapping: tool, inlineSettleGrace: Self.inlineSettleGrace, runPlane: plane.runPlane)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let mounted = harness.mounted
            await #expect(throws: Fixtures.FixtureError.self) {
                _ = try await plane.answer(settlingWithin: Self.inlineSettleGrace) {
                    try await mounted.call(arguments: MountArguments(value: "x"))
                }
            }
            await harness.runPlane.joinRunBodies()
            return context
        }

        let span = try Self.expectBackgroundCall(
            in: context, toolName: tool.name, outcomeValue: QueueOutcome.failed.rawValue, isSettledInline: true)
        #expect(span.status == SpanStatus(code: .error))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.errorType)
                == .string(String(reflecting: Fixtures.FixtureError.self)))
    }

    @Test("a background run that times out inside the settle period records timed_out with no error status, and throws the timeout")
    func aBackgroundRunThatTimesOutInlineIsNotAnError() async throws {
        let tool = Fixtures.SleepingTool()
        let plane = await ManualSettlePlane.make()
        let harness = Fixtures.backgroundHarness(
            wrapping: tool, timeout: Fixtures.shortInterval, inlineSettleGrace: Self.inlineSettleGrace,
            runPlane: plane.runPlane)
        let timeout = ToolMountError.timedOut(tool: tool.name, timeoutSeconds: Fixtures.shortInterval)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let mounted = harness.mounted
            let call = plane.start { try await mounted.call(arguments: MountArguments(value: "x")) }
            // Two timers wait: the timeout of the run and the settle period
            // of the call. Only the timeout ends at its own length.
            try await plane.clock.elapseOneTimer(Fixtures.shortInterval, among: 2) { _ = await call.task.result }
            await #expect(throws: timeout) {
                _ = try await plane.answer(of: call, settlingWithin: Self.inlineSettleGrace)
            }
            await harness.runPlane.joinRunBodies()
            return context
        }

        let span = try Self.expectBackgroundCall(
            in: context, toolName: tool.name, outcomeValue: QueueOutcome.timedOut.rawValue, isSettledInline: true)
        #expect(span.status == nil)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.errorType) == nil)
    }

    @Test("a background run that continues after the settle period records succeeded and tool.settled_inline=false over the start and the full settle wait")
    func aBackgroundRunThatContinuesTimesTheStartAndTheSettleWait() async throws {
        let gate = RunLatch()
        let tool = Fixtures.GatedTool(gate: gate)
        let clock = ManualRunClock()
        let harness = Fixtures.backgroundHarness(
            wrapping: tool, inlineSettleGrace: Self.pendingSettleGrace, runPlane: RunPlane(clock: clock))

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let calling = Task { try await harness.mounted.call(arguments: MountArguments(value: "x")) }
            // A call that sets no settle timer lets the test go on, and the
            // checks below fail.
            await clock.waitForSleepers(atLeast: 1) { _ = await calling.result }
            // While the call waits for the settle period, the tool span and
            // the timer are still open.
            #expect(!context.spans.contains { $0.operationName == ExtrasTelemetry.SpanName.tool })
            #expect(!context.metricRecords.contains { $0.label == ExtrasTelemetry.MetricName.toolDuration })
            let rendered = try await clock.elapse(Self.pendingSettleGrace, endingWait: calling)
            #expect(try Fixtures.decodeEnvelope(rendered).isPending)
            gate.open()
            await harness.runPlane.joinRunBodies()
            return context
        }

        let span = try Self.expectBackgroundCall(
            in: context, toolName: tool.name, outcomeValue: QueueOutcome.succeeded.rawValue, isSettledInline: false)
        _ = try Self.expectSameInterval(
            in: context, span: span, toolName: tool.name, outcomeValue: QueueOutcome.succeeded.rawValue)
    }

    @Test("a background run that the sweep settles while its body still runs records the outcome of the run plane, not succeeded")
    func aBackgroundRunThatTheSweepSettlesRecordsTheRunPlaneOutcome() async throws {
        let gate = RunLatch()
        let tool = Fixtures.GatedProcessTool(gate: gate, processCanceler: { .stopped })
        let clock = ManualRunClock()
        let harness = Fixtures.backgroundHarness(
            wrapping: tool, inlineSettleGrace: Self.inlineSettleGrace, runPlane: RunPlane(clock: clock))

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let answer = Task { try await harness.mounted.call(arguments: MountArguments(value: "x")) }
            // The run plane tracks the run before its body starts. A call
            // that ends first lets the test go on, and the checks fail.
            await Waits.untilFirstEnds({ await tool.started.waitUntilOpen() }, { _ = await answer.result })
            // The sweep settles the run, and the settlement resumes the wait
            // of the call before the sweep returns. Then the move of the
            // clock cannot change the answer. A call that did not see the
            // settlement ends at its deadline, and the checks fail.
            _ = await harness.runPlane.sweep()
            clock.advance(by: .seconds(Self.inlineSettleGrace))
            _ = try await answer.value
            // The body still waits on its gate. It ends here, thus the
            // capture holds each record of the run when the test reads it.
            gate.open()
            await harness.runPlane.joinRunBodies()
            return context
        }

        _ = try Self.expectBackgroundCall(
            in: context, toolName: tool.name, outcomeValue: QueueOutcome.stopped.rawValue, isSettledInline: true)
    }

    @Test("a background call puts no tool output and no terminal detail on the telemetry")
    func aBackgroundCallCarriesNoToolContent() async throws {
        let succeeding = Fixtures.FastTool()
        let failing = Fixtures.ThrowingTool()
        let plane = await ManualSettlePlane.make()
        let succeedingHarness = Fixtures.backgroundHarness(
            wrapping: succeeding, inlineSettleGrace: Self.inlineSettleGrace, runPlane: plane.runPlane)
        let failingHarness = Fixtures.backgroundHarness(
            wrapping: failing, inlineSettleGrace: Self.inlineSettleGrace, runPlane: plane.runPlane)
        let failureDetail = String(describing: Fixtures.FixtureError())

        let context = try await TelemetryCapture.run(forbidding: [Self.backgroundContent, failureDetail]) { context in
            let succeedingTool = succeedingHarness.mounted
            let failingTool = failingHarness.mounted
            let output = try await plane.answer(settlingWithin: Self.inlineSettleGrace) {
                try await succeedingTool.call(arguments: MountArguments(value: Self.backgroundContent))
            }
            #expect(output.contains(Self.backgroundContent))
            await #expect(throws: Fixtures.FixtureError.self) {
                _ = try await plane.answer(settlingWithin: Self.inlineSettleGrace) {
                    try await failingTool.call(arguments: MountArguments(value: Self.backgroundContent))
                }
            }
            await succeedingHarness.runPlane.joinRunBodies()
            await failingHarness.runPlane.joinRunBodies()
            return context
        }

        // A capture that recorded nothing would pass with no issue, thus the
        // test states what the capture measured.
        try Self.expectToolCallMetrics(
            in: context, toolName: succeeding.name, outcomeValue: QueueOutcome.succeeded.rawValue)
        try Self.expectToolCallMetrics(in: context, toolName: failing.name, outcomeValue: QueueOutcome.failed.rawValue)
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

    @Test("a bound call whose report is held records its span and its duration only after the report, over the same interval")
    func aBoundCallTimesItsReport() async throws {
        let tool = Fixtures.AttachingNonStringOutputTool()
        let sink = HeldReportSink()
        let bound = ContextBindingTool(wrapping: tool, site: Fixtures.site(runPlane: RunPlane(), sink: sink))

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let calling = Task { try await bound.call(arguments: MountArguments(value: "x")) }
            // A call that ends with no report lets the test go on, and the
            // checks below fail.
            await Waits.untilFirstEnds({ await sink.arrived.waitUntilOpen() }, { _ = await calling.result })
            // While the report is held, the span and the timer are still open.
            #expect(context.spans.isEmpty)
            #expect(!context.metricRecords.contains { $0.label == ExtrasTelemetry.MetricName.toolDuration })
            sink.release.open()
            _ = try await calling.value
            return context
        }

        try Self.expectOneCall(in: context, toolName: tool.name, outcome: .succeeded)
        _ = try Self.expectSameInterval(
            in: context, span: try #require(context.spans.first), toolName: tool.name,
            outcomeValue: OperationOutcome.succeeded.rawValue)
    }

    /// Expects that the duration on the timer of one call and the duration
    /// of its span measure the same interval, inside
    /// ``sameIntervalTolerance``.
    ///
    /// - Parameters:
    ///   - context: The capture of the call.
    ///   - span: The tool span of the call.
    ///   - toolName: The model-facing name of the tool.
    ///   - outcomeValue: The expected `tool.outcome` value.
    /// - Returns: The duration on the timer.
    /// - Throws: When the capture has no such timer, or the timer has no
    ///   value.
    private static func expectSameInterval(
        in context: TelemetryCapture.Context,
        span: FinishedInMemorySpan,
        toolName: String,
        outcomeValue: String
    ) throws -> Duration {
        let timer = try context.metricsFactory.expectTimer(
            ExtrasTelemetry.MetricName.toolDuration, dimensions(toolName: toolName, outcomeValue: outcomeValue))
        let recorded = Duration.nanoseconds(try #require(timer.values.first))
        let spanned = Duration.nanoseconds(
            Int64(span.endInstant.nanosecondsSinceEpoch - span.startInstant.nanosecondsSinceEpoch))
        #expect(max(spanned, recorded) - min(spanned, recorded) < sameIntervalTolerance)
        return recorded
    }

    /// Expects that the capture holds the telemetry of one background call:
    /// one tool span with the background run kind, the outcome and
    /// `tool.settled_inline`, and one count and one duration with the tool
    /// name and the outcome as their dimensions.
    ///
    /// - Parameters:
    ///   - context: The capture of the call.
    ///   - toolName: The model-facing name of the tool.
    ///   - outcomeValue: The expected `tool.outcome` value.
    ///   - isSettledInline: The expected `tool.settled_inline` value.
    /// - Returns: The tool span of the call.
    /// - Throws: When the capture has no tool span, or no such counter or
    ///   timer.
    private static func expectBackgroundCall(
        in context: TelemetryCapture.Context,
        toolName: String,
        outcomeValue: String,
        isSettledInline: Bool
    ) throws -> FinishedInMemorySpan {
        try expectToolCallMetrics(in: context, toolName: toolName, outcomeValue: outcomeValue)
        let toolSpans = context.spans.filter { $0.operationName == ExtrasTelemetry.SpanName.tool }
        #expect(toolSpans.count == 1)
        let span = try #require(toolSpans.first)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.runKind) == .string("background"))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.outcome) == .string(outcomeValue))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.settledInline) == .bool(isSettledInline))
        return span
    }

    /// The dimensions of each tool-call metric of one call.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool.
    ///   - outcomeValue: The `tool.outcome` value of the call.
    /// - Returns: The tool name and the outcome, in that order.
    private static func dimensions(toolName: String, outcomeValue: String) -> [(String, String)] {
        [
            (ExtrasTelemetry.AttributeKey.toolName, toolName),
            (ExtrasTelemetry.AttributeKey.outcome, outcomeValue),
        ]
    }

    /// Expects that the capture holds the telemetry of one tool call: one
    /// span, one "enter" log record, one count on the counter and one
    /// duration on the timer. Each metric has the tool name and the outcome
    /// as its only dimensions.
    ///
    /// - Parameters:
    ///   - context: The capture of the call.
    ///   - toolName: The model-facing name of the tool.
    ///   - outcome: How the call ended. Its wire value is the expected
    ///     `tool.outcome` value, thus it must be a case that this package
    ///     knows.
    ///   - metricLabels: The sorted metric labels of the call. The default is
    ///     the tool-call metrics of a call that sends no event upstream.
    /// - Throws: When the capture has no such counter or timer.
    private static func expectOneCall(
        in context: TelemetryCapture.Context,
        toolName: String,
        outcome: OperationOutcome,
        metricLabels: [String] = Fixtures.metricLabelsOfOneToolCall
    ) throws {
        try expectOneCall(in: context, toolName: toolName, outcomeValue: outcome.rawValue, metricLabels: metricLabels)
    }

    /// Expects that the capture holds the telemetry of one tool call, with
    /// `outcomeValue` as the `tool.outcome` dimension of each metric.
    ///
    /// - Parameters:
    ///   - context: The capture of the call.
    ///   - toolName: The model-facing name of the tool.
    ///   - outcomeValue: The expected `tool.outcome` value.
    ///   - metricLabels: The sorted metric labels of the call. The default is
    ///     the tool-call metrics of a call that sends no event upstream.
    /// - Throws: When the capture has no such counter or timer.
    private static func expectOneCall(
        in context: TelemetryCapture.Context,
        toolName: String,
        outcomeValue: String,
        metricLabels: [String] = Fixtures.metricLabelsOfOneToolCall
    ) throws {
        try expectToolCallMetrics(in: context, toolName: toolName, outcomeValue: outcomeValue)
        #expect(context.metricRecords.map(\.label) == metricLabels)
        #expect(context.spans.map(\.operationName) == [ExtrasTelemetry.SpanName.tool])
        #expect(context.logRecords.map { "\($0.message)" } == [
            ExtrasTelemetry.EnterRecord.message(forSpanNamed: ExtrasTelemetry.SpanName.tool),
        ])
    }

    /// Expects that the capture holds the tool-call metrics of one call: one
    /// count on the counter and one duration on the timer, with `toolName`
    /// and `outcomeValue` as their dimensions.
    ///
    /// - Parameters:
    ///   - context: The capture of the call.
    ///   - toolName: The model-facing name of the tool.
    ///   - outcomeValue: The expected `tool.outcome` value.
    /// - Throws: When the capture has no such counter or timer.
    private static func expectToolCallMetrics(
        in context: TelemetryCapture.Context,
        toolName: String,
        outcomeValue: String
    ) throws {
        let dimensions = Self.dimensions(toolName: toolName, outcomeValue: outcomeValue)
        let counter = try context.metricsFactory.expectCounter(ExtrasTelemetry.MetricName.toolCalls, dimensions)
        let timer = try context.metricsFactory.expectTimer(ExtrasTelemetry.MetricName.toolDuration, dimensions)
        #expect(counter.values == [oneCall])
        #expect(timer.values.count == 1)
    }
}
