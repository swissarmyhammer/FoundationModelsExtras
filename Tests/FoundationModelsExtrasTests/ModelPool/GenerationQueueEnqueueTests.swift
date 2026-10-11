@testable import FoundationModelsExtras
import Metrics
import MetricsTestKit
import Testing

/// `enqueue` puts a job in the generation queue and returns at once. It
/// counts the job and puts it in the worker input in the same step as
/// `submit`, so the jobs run in the order that they enter the queue.
///
/// The import is `@testable`, because `enqueue` is internal: only the model
/// pool uses it.
@Suite("Generation queue: enqueue puts a job in the queue with no wait")
struct GenerationQueueEnqueueTests {
    /// The number of jobs in the order test: the holder, two enqueued jobs
    /// and one submitted job.
    private static let jobsInTheOrderTest = 4

    /// The number of jobs that wait behind the holder before the second
    /// enqueue: the first enqueued job and the submitted job.
    private static let waitingBeforeTheSecondEnqueue = 2

    /// Enqueues a job on `queue` that writes `"holder"` and then holds the
    /// worker until the test finishes the returned continuation. Returns when
    /// the job runs.
    ///
    /// - Parameters:
    ///   - queue: The queue.
    ///   - log: The log.
    /// - Returns: Finish this to end the job.
    /// - Throws: An `ExpectationFailedError` when the job never ran.
    private static func enqueueHolder(
        on queue: GenerationQueue, log: Recorder<String>
    ) async throws -> AsyncStream<Void>.Continuation {
        let (mayEnd, end) = AsyncStream.makeStream(of: Void.self)
        queue.enqueue {
            log.append("holder")
            for await _ in mayEnd {}
        }
        try #require(await BoundedWait.conditionReached("the holder runs") { log.values == ["holder"] })
        return end
    }

    @Test("enqueued jobs and a submitted job run in the order that they enter the queue")
    func enqueuedAndSubmittedJobsRunInEntryOrder() async throws {
        let queue = GenerationQueue()
        let log = Recorder<String>()
        let endHolder = try await Self.enqueueHolder(on: queue, log: log)

        queue.enqueue { log.append("first enqueued") }
        let submitted = Task { try await queue.submit { log.append("submitted") } }
        try #require(await BoundedWait.conditionReached("the submitted job waits") {
            await queue.waitingCount == Self.waitingBeforeTheSecondEnqueue
        })
        queue.enqueue { log.append("second enqueued") }
        let waitingBeforeTheEnd = await queue.waitingCount
        endHolder.finish()
        try await submitted.value
        try #require(await BoundedWait.conditionReached("every job runs") {
            log.values.count == Self.jobsInTheOrderTest
        })

        #expect(waitingBeforeTheEnd == Self.jobsInTheOrderTest - 1)
        #expect(log.values == ["holder", "first enqueued", "submitted", "second enqueued"])
    }

    @Test("a job enqueued from a cancelled task still runs")
    func aJobEnqueuedFromACancelledTaskRuns() async throws {
        let queue = GenerationQueue()
        let log = Recorder<String>()

        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            queue.enqueue { log.append("ran") }
        }.value

        #expect(await BoundedWait.conditionReached("the enqueued job runs") { log.values == ["ran"] })
    }

    /// The model of the queue in the test of a model queue.
    private static let model: ModelRef = "org/queued-model"

    /// The depth values of one job: up at the enqueue, down at the end.
    private static let depthOfOneJob: [Double] = [1, 0]

    /// The values of the task counter after one completed job.
    private static let oneTask: [Int64] = [1]

    /// Gives the dimensions of the depth meter of a queue.
    ///
    /// - Parameter telemetry: The recorder of the queue.
    /// - Returns: The queue name, then the model ref when the queue has one.
    private static func queueDimensions(of telemetry: QueueTelemetry) -> [(String, String)] {
        [(ExtrasTelemetry.DimensionKey.queueName, telemetry.name.rawValue)]
            + (telemetry.model.map { [(ExtrasTelemetry.DimensionKey.modelRef, $0.stringValue)] } ?? [])
    }

    /// Gives the dimensions of the timers and of the counter of a queue for
    /// one job that succeeded.
    ///
    /// - Parameter telemetry: The recorder of the queue.
    /// - Returns: The dimensions of the queue, then the outcome.
    private static func succeededDimensions(of telemetry: QueueTelemetry) -> [(String, String)] {
        queueDimensions(of: telemetry) + [(ExtrasTelemetry.DimensionKey.queueOutcome, QueueOutcome.succeeded.rawValue)]
    }

    @Test("an enqueued job records one succeeded task of the generation queue with the factory of the caller")
    func anEnqueuedJobRecordsOneTask() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()
        let telemetry = QueueTelemetry(name: .generation)

        withMetricsFactory(metrics) {
            queue.enqueue {}
        }

        let completed = await BoundedWait.conditionReached("the enqueued job completes") {
            (try? metrics.expectCounter(ExtrasTelemetry.MetricName.queueTasks, Self.succeededDimensions(of: telemetry)))?
                .values == Self.oneTask
        }
        #expect(completed)
        let depth = try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, Self.queueDimensions(of: telemetry))
        #expect(depth.values == Self.depthOfOneJob)
        let run = try metrics.expectTimer(ExtrasTelemetry.MetricName.queueRun, Self.succeededDimensions(of: telemetry))
        #expect(run.values.count == Self.oneTask.count)
    }

    @Test("a queue made with a recorder of one model records its queue name and the model ref")
    func aModelQueueRecordsItsNameAndModel() async throws {
        let metrics = TestMetrics()
        let telemetry = QueueTelemetry(name: .model, model: Self.model)
        let queue = GenerationQueue(telemetry: telemetry)

        try await withMetricsFactory(metrics) {
            try await queue.submit {}
        }

        let tasks = try metrics.expectCounter(
            ExtrasTelemetry.MetricName.queueTasks, Self.succeededDimensions(of: telemetry))
        #expect(tasks.values == Self.oneTask)
        let depth = try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, Self.queueDimensions(of: telemetry))
        #expect(depth.values == Self.depthOfOneJob)
    }
}
