@testable import FoundationModelsExtras
import Metrics
import MetricsTestKit
import Testing

/// ``QueueTelemetry`` records the depth of a queue, and the wait time, the run
/// time and the count of each task when it completes.
@Suite("QueueTelemetry: the depth, the wait time, the run time and the count of a queue")
struct QueueTelemetryTests {
    /// The queue that each test records.
    private static let queueName = QueueName.generation

    /// The model of the queue in the tests that set one.
    private static let model: ModelRef = "org/model@main"

    /// The depth of the queue when one task is not finished.
    private static let oneTask: Double = 1

    /// The depth of the queue when two tasks are not finished.
    private static let twoTasks: Double = 2

    /// The depth of the queue when each task is finished.
    private static let noTask: Double = 0

    /// The count that one completed task adds to the task counter.
    private static let oneCount: Int64 = 1

    /// The count of durations that one completed task records on a timer.
    private static let oneDuration = 1

    /// The smallest duration that a timer can record, in nanoseconds.
    private static let noTime: Int64 = 0

    @Test("the depth goes up at enqueue and back to 0 at completion")
    func theDepthGoesUpAndBackToZero() throws {
        let metrics = TestMetrics()
        let telemetry = QueueTelemetry(name: Self.queueName)

        withMetricsFactory(metrics) {
            var ticket = telemetry.enqueued()
            telemetry.started(&ticket)
            telemetry.completed(ticket, outcome: .succeeded)
        }

        let depth = try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, Self.depthDimensions(model: nil))
        #expect(depth.values == [Self.oneTask, Self.noTask])
    }

    @Test("the depth counts each task that is not finished, and goes back to 0 after each task completes")
    func theDepthCountsEachTask() throws {
        let metrics = TestMetrics()
        let telemetry = QueueTelemetry(name: Self.queueName)

        withMetricsFactory(metrics) {
            var first = telemetry.enqueued()
            var second = telemetry.enqueued()
            telemetry.started(&first)
            telemetry.completed(first, outcome: .succeeded)
            telemetry.started(&second)
            telemetry.completed(second, outcome: .failed)
        }

        let depth = try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, Self.depthDimensions(model: nil))
        #expect(depth.values == [Self.oneTask, Self.twoTasks, Self.oneTask, Self.noTask])
    }

    @Test("a completed task records one wait time, one run time and one count with the queue name and the outcome")
    func aCompletedTaskRecordsItsTiming() throws {
        let metrics = TestMetrics()
        let telemetry = QueueTelemetry(name: Self.queueName)

        withMetricsFactory(metrics) {
            var ticket = telemetry.enqueued()
            telemetry.started(&ticket)
            telemetry.completed(ticket, outcome: .timedOut)
        }

        try Self.expectOneTask(in: metrics, model: nil, outcome: .timedOut, ran: true)
    }

    @Test("a queue of one model adds the model ref to each dimension list")
    func aModelQueueAddsTheModelRef() throws {
        let metrics = TestMetrics()
        let telemetry = QueueTelemetry(name: Self.queueName, model: Self.model)

        withMetricsFactory(metrics) {
            var ticket = telemetry.enqueued()
            telemetry.started(&ticket)
            telemetry.completed(ticket, outcome: .succeeded)
        }

        let depth = try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, Self.depthDimensions(model: Self.model))
        #expect(depth.values == [Self.oneTask, Self.noTask])
        try Self.expectOneTask(in: metrics, model: Self.model, outcome: .succeeded, ran: true)
    }

    @Test("a task cancelled before it starts records a wait time, no run time and the outcome cancelled")
    func aTaskCancelledBeforeStartRecordsNoRunTime() throws {
        let metrics = TestMetrics()
        let telemetry = QueueTelemetry(name: Self.queueName)

        withMetricsFactory(metrics) {
            let ticket = telemetry.enqueued()
            telemetry.completed(ticket, outcome: .cancelled)
        }

        try Self.expectOneTask(in: metrics, model: nil, outcome: .cancelled, ran: false)
        let depth = try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, Self.depthDimensions(model: nil))
        #expect(depth.lastValue == Self.noTask)
    }

    @Test("a start and a completion in a detached task reach the factory of the submitter")
    func aDetachedCompletionReachesTheSubmitterFactory() async throws {
        let metrics = TestMetrics()
        let telemetry = QueueTelemetry(name: Self.queueName)

        let ticket = withMetricsFactory(metrics) {
            telemetry.enqueued()
        }
        await Task.detached {
            var running = ticket
            telemetry.started(&running)
            telemetry.completed(running, outcome: .succeeded)
        }.value

        try Self.expectOneTask(in: metrics, model: nil, outcome: .succeeded, ran: true)
        let depth = try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, Self.depthDimensions(model: nil))
        #expect(depth.values == [Self.oneTask, Self.noTask])
    }

    @Test("each queue name and each queue outcome has its fixed raw value")
    func theQueueVocabularyHasItsRawValues() {
        #expect(QueueName.allCases.map(\.rawValue) == [
            "model", "admission", "generation", "run_plane", "elicitation", "tool_events", "mailbox",
        ])
        #expect(QueueOutcome.allCases.map(\.rawValue) == [
            "succeeded", "failed", "timed_out", "stopped", "cancelled", "lost", "other",
        ])
    }

    @Test("each queue metric name has the module name as its prefix, and each dimension key has its dotted name")
    func theQueueMetricNamesHaveTheModulePrefix() {
        #expect(ExtrasTelemetry.MetricName.queueDepth == "FoundationModelsExtras.queue.depth")
        #expect(ExtrasTelemetry.MetricName.queueWait == "FoundationModelsExtras.queue.wait")
        #expect(ExtrasTelemetry.MetricName.queueRun == "FoundationModelsExtras.queue.run")
        #expect(ExtrasTelemetry.MetricName.queueTasks == "FoundationModelsExtras.queue.tasks")
        #expect(ExtrasTelemetry.DimensionKey.queueName == "queue.name")
        #expect(ExtrasTelemetry.DimensionKey.modelRef == "model.ref")
        #expect(ExtrasTelemetry.DimensionKey.queueOutcome == "queue.outcome")
    }

    /// Gives the dimensions of the depth meter of the test queue.
    ///
    /// - Parameter model: The model of the queue, or `nil` for no model.
    /// - Returns: The queue name, then the model ref when `model` is set.
    private static func depthDimensions(model: ModelRef?) -> [(String, String)] {
        [(ExtrasTelemetry.DimensionKey.queueName, queueName.rawValue)]
            + (model.map { [(ExtrasTelemetry.DimensionKey.modelRef, $0.stringValue)] } ?? [])
    }

    /// Expects that `metrics` holds the completion of one task: one wait
    /// time, one count, and one run time when the task ran.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - model: The model of the queue, or `nil` for no model.
    ///   - outcome: How the task ended.
    ///   - ran: `true` when the task started before it completed.
    /// - Throws: When `metrics` has no such timer or counter.
    private static func expectOneTask(
        in metrics: TestMetrics,
        model: ModelRef?,
        outcome: QueueOutcome,
        ran: Bool
    ) throws {
        let dimensions = depthDimensions(model: model) + [(ExtrasTelemetry.DimensionKey.queueOutcome, outcome.rawValue)]
        let wait = try metrics.expectTimer(ExtrasTelemetry.MetricName.queueWait, dimensions)
        let tasks = try metrics.expectCounter(ExtrasTelemetry.MetricName.queueTasks, dimensions)
        #expect(wait.values.count == oneDuration)
        #expect(wait.values.allSatisfy { $0 >= noTime })
        #expect(tasks.values == [oneCount])
        if ran {
            let run = try metrics.expectTimer(ExtrasTelemetry.MetricName.queueRun, dimensions)
            #expect(run.values.count == oneDuration)
            #expect(run.values.allSatisfy { $0 >= noTime })
        } else {
            #expect(throws: TestMetricsError.self) {
                try metrics.expectTimer(ExtrasTelemetry.MetricName.queueRun, dimensions)
            }
        }
    }
}
