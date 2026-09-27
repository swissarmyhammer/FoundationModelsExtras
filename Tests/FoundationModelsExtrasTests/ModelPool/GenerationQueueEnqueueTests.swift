@testable import FoundationModelsExtras
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
}
