import Logging
import Metrics
import TelemetryTestSupport
import Testing
import Tracing

/// ``TelemetryCapture/Context/wait(until:)`` ends when a span ends, a log
/// record arrives, a metric records a value or a metric is removed, and the
/// condition is then true.
/// It ends at once when the condition is already true, and it ends when its
/// task is cancelled.
///
/// Each test that writes a record after the wait starts calls
/// ``TelemetryCapture/Context/waitForWaiters(atLeast:)`` first. Thus the order
/// of the wait and the record is fixed, with no sleep and no poll.
@Suite("TelemetryCapture.Context.wait: a wait ends on the record that makes its condition true")
struct TelemetryCaptureWaitTests {
    /// The name of the span that the tests open.
    private static let spanName = "probe.wait.span"

    /// The message of the log record that the tests write.
    private static let logMessage: Logger.Message = "probe wait record"

    /// The label of the counter that the tests make.
    private static let counterLabel = "probe.wait.calls"

    /// The value that the counter of the tests records.
    private static let counterValue: Int64 = 3

    /// The label of the meter that the tests make.
    private static let meterLabel = "probe.wait.depth"

    /// The value that the meter of the tests records.
    private static let meterValue: Double = 5

    @Test("a wait that starts before a span ends ends when the span ends")
    func aWaitBeforeASpanEndsWhenTheSpanEnds() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            async let waited: Void = context.wait(until: Self.hasSpan)
            await context.waitForWaiters(atLeast: 1)
            #expect(context.spans.isEmpty)

            context.tracer.withSpan(Self.spanName) { _ in }
            await waited

            #expect(context.spans.map(\.operationName) == [Self.spanName])
        }
    }

    @Test("a wait that starts before a log record ends when the record arrives")
    func aWaitBeforeALogRecordEndsWhenTheRecordArrives() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            async let waited: Void = context.wait(until: Self.hasLogRecord)
            await context.waitForWaiters(atLeast: 1)
            #expect(context.logRecords.isEmpty)

            context.logger.info(Self.logMessage)
            await waited

            #expect(context.logRecords.map(\.message) == [Self.logMessage])
        }
    }

    @Test("a wait that starts before a metric record ends when the metric records the value")
    func aWaitBeforeAMetricRecordEndsWhenTheMetricRecords() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            async let waited: Void = context.wait(until: Self.hasCounterValue)
            await context.waitForWaiters(atLeast: 1)
            #expect(context.metricRecords.isEmpty)

            Metrics.Counter(label: Self.counterLabel).increment(by: Self.counterValue)
            await waited

            let counter = try context.metricsFactory.expectCounter(Self.counterLabel)
            #expect(counter.values == [Self.counterValue])
        }
    }

    @Test("a wait that starts before a meter record ends when the meter of the observed factory records the value")
    func aWaitBeforeAMeterRecordEndsWhenTheMeterRecords() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            async let waited: Void = context.wait(until: Self.hasMeterValue)
            await context.waitForWaiters(atLeast: 1)
            #expect(context.metricRecords.isEmpty)

            Metrics.Meter(label: Self.meterLabel, factory: context.observedMetricsFactory).set(Self.meterValue)
            await waited

            let meter = try context.metricsFactory.expectMeter(Self.meterLabel)
            #expect(meter.values == [Self.meterValue])
        }
    }

    @Test("a wait that starts before a counter is destroyed ends when the observed factory removes the counter")
    func aWaitBeforeACounterDestroyEndsWhenTheCounterIsRemoved() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let counter = Metrics.Counter(label: Self.counterLabel, factory: context.observedMetricsFactory)
            #expect(!Self.hasNoCounter(context))

            async let waited: Void = context.wait(until: Self.hasNoCounter)
            await context.waitForWaiters(atLeast: 1)

            counter.destroy()
            await waited

            #expect(context.metricRecords.isEmpty)
        }
    }

    @Test("a wait that starts after the records ends at once")
    func aWaitAfterTheRecordsEndsAtOnce() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            context.tracer.withSpan(Self.spanName) { _ in }
            context.logger.info(Self.logMessage)
            Metrics.Counter(label: Self.counterLabel).increment(by: Self.counterValue)

            await context.wait(until: Self.hasSpan)
            await context.wait(until: Self.hasLogRecord)
            await context.wait(until: Self.hasCounterValue)

            #expect(context.spans.count == 1)
            #expect(context.logRecords.count == 1)
            #expect(context.metricRecords.count == 1)
        }
    }

    @Test("a cancel of the waiting task ends a wait that no record ends")
    func aCancelEndsAWait() async throws {
        let wasCancelled = try await TelemetryCapture.run(forbidding: []) { context in
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await context.wait { _ in false }
                    return Task.isCancelled
                }
                await context.waitForWaiters(atLeast: 1)
                group.cancelAll()
                return await group.next()
            }
        }

        #expect(wasCancelled == true)
    }

    @Test("a wait in a task that was cancelled before the wait ends at once")
    func aWaitInACancelledTaskEndsAtOnce() async throws {
        let wasCancelled = try await TelemetryCapture.run(forbidding: []) { context in
            await withTaskGroup(of: Bool.self) { group in
                group.cancelAll()
                group.addTask {
                    await context.wait { _ in false }
                    return Task.isCancelled
                }
                return await group.next()
            }
        }

        #expect(wasCancelled == true)
    }

    /// Whether the capture holds the span of the tests.
    ///
    /// - Parameter context: The context of the capture.
    /// - Returns: `true` when a span with the name of the tests ended.
    @Sendable
    private static func hasSpan(_ context: TelemetryCapture.Context) -> Bool {
        context.spans.contains { $0.operationName == spanName }
    }

    /// Whether the capture holds the log record of the tests.
    ///
    /// - Parameter context: The context of the capture.
    /// - Returns: `true` when a record with the message of the tests arrived.
    @Sendable
    private static func hasLogRecord(_ context: TelemetryCapture.Context) -> Bool {
        context.logRecords.contains { $0.message == logMessage }
    }

    /// Whether the counter of the tests recorded its value.
    ///
    /// - Parameter context: The context of the capture.
    /// - Returns: `true` when the counter of the tests holds the value of the
    ///   tests.
    @Sendable
    private static func hasCounterValue(_ context: TelemetryCapture.Context) -> Bool {
        (try? context.metricsFactory.expectCounter(counterLabel))?.values == [counterValue]
    }

    /// Whether the meter of the tests recorded its value.
    ///
    /// - Parameter context: The context of the capture.
    /// - Returns: `true` when the meter of the tests holds the value of the
    ///   tests.
    @Sendable
    private static func hasMeterValue(_ context: TelemetryCapture.Context) -> Bool {
        (try? context.metricsFactory.expectMeter(meterLabel))?.values == [meterValue]
    }

    /// Whether the capture holds no counter with the label of the tests.
    ///
    /// - Parameter context: The context of the capture.
    /// - Returns: `true` when no counter with the label of the tests is in the
    ///   metrics factory of the capture.
    @Sendable
    private static func hasNoCounter(_ context: TelemetryCapture.Context) -> Bool {
        (try? context.metricsFactory.expectCounter(counterLabel)) == nil
    }
}
