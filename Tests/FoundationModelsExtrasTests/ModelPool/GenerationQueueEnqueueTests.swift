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
    /// A worker that never runs a job gives no event, thus the wait for the
    /// holder has no fault event of its own. Each later wait of a test does.
    ///
    /// - Parameters:
    ///   - queue: The queue.
    ///   - log: The log.
    /// - Returns: Finish this to end the job.
    private static func enqueueHolder(
        on queue: GenerationQueue, log: Recorder<String>
    ) async -> AsyncStream<Void>.Continuation {
        let (mayEnd, end) = AsyncStream.makeStream(of: Void.self)
        queue.enqueue {
            log.append("holder")
            for await _ in mayEnd {}
        }
        await log.waitUntil { $0.contains("holder") }
        return end
    }

    /// Waits until each job that entered `queue` before this call ended. The
    /// queue runs its jobs first in first out, thus an empty job that the
    /// call submits runs after them.
    ///
    /// - Parameter queue: The queue.
    /// - Throws: The error of the submit.
    private static func waitForTheEarlierJobs(of queue: GenerationQueue) async throws {
        try await queue.submit {}
    }

    @Test("enqueued jobs and a submitted job run in the order that they enter the queue")
    func enqueuedAndSubmittedJobsRunInEntryOrder() async throws {
        let queue = GenerationQueue()
        let log = Recorder<String>()
        let endHolder = await Self.enqueueHolder(on: queue, log: log)

        queue.enqueue { log.append("first enqueued") }
        let queued = RunLatch()
        let submitted = Task {
            try await queue.submit(onQueued: { queued.open() }) { log.append("submitted") }
        }
        await Waits.untilFirstEnds({ await queued.waitUntilOpen() }, { _ = await submitted.result })
        try #require(await queue.waitingCount == Self.waitingBeforeTheSecondEnqueue)
        queue.enqueue { log.append("second enqueued") }
        let waitingBeforeTheEnd = await queue.waitingCount
        endHolder.finish()
        try await submitted.value
        try await Self.waitForTheEarlierJobs(of: queue)

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
        try await Self.waitForTheEarlierJobs(of: queue)

        #expect(log.values == ["ran"])
    }

    /// The depth values of one job: up at the enqueue, down at the end.
    private static let depthOfOneJob: [Double] = [1, 0]

    @Test("an enqueued job records one succeeded task of the generation queue with the factory of the caller")
    func anEnqueuedJobRecordsOneTask() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()
        let dimensions = QueueMetricDimensions.queue(of: QueueTelemetry(name: .generation))

        withMetricsFactory(metrics) {
            queue.enqueue {}
        }

        // The empty job runs outside the factory, thus it records nothing in
        // `metrics`.
        try await Self.waitForTheEarlierJobs(of: queue)
        try QueueMetricExpectations.expectCompletedJobs(in: metrics, queue: dimensions, outcome: .succeeded, ran: true)
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: dimensions) == Self.depthOfOneJob)
    }
}
