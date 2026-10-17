import FoundationModelsExtras
import InMemoryTracing
import Metrics
import MetricsTestKit
import TelemetryTestSupport
import Testing
import Tracing
import ULID

/// The generation queue is a work queue with one worker.
///
/// A submitter gives the queue one item and waits only for the result of that
/// item. One worker runs the items one at a time, first in first out, on a
/// task that the worker makes. These tests read the order, the overlap and
/// the cancel of the items from the items themselves, and read the state of
/// the queue through ``GenerationQueue/isRunning`` and
/// ``GenerationQueue/waitingCount``.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees.
@Suite("Generation queue: one worker runs the items, first in first out")
struct GenerationQueueWorkerTests {
    /// Records which items started, in order, and how many ran at one time.
    private actor ItemLog {
        /// The names of the items that started, in the order they started.
        private(set) var started: [String] = []

        /// The items that run now.
        private var active = 0

        /// The largest number of items that ran at one time.
        private(set) var peak = 0

        /// Records that the item `name` started.
        ///
        /// - Parameter name: The name of the item.
        func enter(_ name: String) {
            started.append(name)
            active += 1
            peak = max(peak, active)
        }

        /// Records that one item ended.
        func exit() {
            active -= 1
        }
    }

    /// Keeps the outcome of one submitter, so a test reads it while the
    /// submitter task is still a value of the test.
    private final class OutcomeBox<Value: Sendable>: Sendable {
        /// The outcome, when the submitter has one.
        private let stored = Recorder<Result<Value, any Error>>()

        /// The outcome, or `nil` while the submitter waits.
        var outcome: Result<Value, any Error>? { stored.values.first }

        /// Keeps `outcome`.
        ///
        /// - Parameter outcome: The outcome of the submitter.
        func store(_ outcome: Result<Value, any Error>) {
            stored.append(outcome)
        }

        /// Waits until the box holds an outcome. The wait ends at a cancel of
        /// the waiting task.
        func waitForOutcome() async {
            _ = await stored.waitUntil { !$0.isEmpty }
        }
    }

    /// A flag that a test or an item sets, and the number of times it was set.
    private final class Flag: Sendable {
        /// One value for each set of the flag.
        private let sets = Recorder<Bool>()

        /// The number of times the flag was set.
        var count: Int { sets.values.count }

        /// Whether the flag was set.
        var isSet: Bool { count > 0 }

        /// Sets the flag.
        func set() {
            sets.append(true)
        }

        /// Waits until the flag is set. The wait ends at a cancel of the
        /// waiting task.
        func waitUntilSet() async {
            _ = await sets.waitUntil { !$0.isEmpty }
        }
    }

    /// Waits until `flag` is set.
    ///
    /// - Parameter flag: The flag to wait for.
    private static func waitUntilSet(_ flag: Flag) async {
        await flag.waitUntilSet()
    }

    /// A result that sets a flag when its last reference goes.
    private final class TrackedResult: Sendable {
        /// The flag that the deinit sets.
        private let released: Flag

        /// Makes a result that sets `released` in its deinit.
        ///
        /// - Parameter released: The flag to set.
        init(released: Flag) {
            self.released = released
        }

        /// Sets the flag.
        deinit { released.set() }
    }

    /// How many times the release test submits an item and drops its result.
    private static let releaseRepetitions = 1000

    /// The number of items that wait behind the first item in the FIFO test.
    private static let itemsBehindTheFirst = 2

    /// How many times the race test races a cancel against the start of an
    /// item.
    private static let raceRepetitions = 300

    /// How many times the order test submits a line of items.
    private static let orderRepetitions = 200

    /// The number of items in one line of the order test.
    private static let itemsInLine = 8

    /// The value the raced item returns when its body runs.
    private static let racedValue = 7

    /// The value of the item that follows the raced item.
    private static let nextValue = 11

    /// Submits `body` to `queue` on a new task, and keeps the outcome of that
    /// task in the returned box.
    ///
    /// - Parameters:
    ///   - queue: The queue to submit to.
    ///   - onQueued: Called when the item must wait behind another item.
    ///   - body: The item.
    /// - Returns: The task of the submitter, and the box of its outcome.
    private static func submit<Value: Sendable>(
        to queue: GenerationQueue,
        onQueued: @escaping @Sendable () -> Void = {},
        _ body: @escaping @Sendable () async throws -> Value
    ) -> (task: Task<Void, Never>, box: OutcomeBox<Value>) {
        let box = OutcomeBox<Value>()
        let task = Task {
            let outcome: Result<Value, any Error>
            do {
                outcome = .success(try await queue.submit(onQueued: onQueued, body))
            } catch {
                outcome = .failure(error)
            }
            box.store(outcome)
        }
        return (task, box)
    }

    /// Waits until `box` holds an outcome. A queue that never resumes the
    /// submitter gives no event, thus this wait has no other end.
    ///
    /// - Parameters:
    ///   - box: The box of one submitter.
    ///   - label: What the outcome means, named in the recorded issue.
    /// - Returns: The outcome.
    /// - Throws: An `ExpectationFailedError` when the box holds no outcome
    ///   after the wait, which occurs only at a cancel of the test.
    private static func outcome<Value: Sendable>(
        of box: OutcomeBox<Value>, named label: String
    ) async throws -> Result<Value, any Error> {
        await box.waitForOutcome()
        return try #require(box.outcome, "\(label)")
    }

    /// Waits until `flag` is set, or until `box` holds an outcome. An item
    /// that ends or fails before it sets the flag thus ends the wait.
    ///
    /// - Parameters:
    ///   - flag: The flag that the item, or its `onQueued`, sets.
    ///   - box: The box of the submitter of the item.
    private static func waitUntilSet<Value: Sendable>(_ flag: Flag, orUntilOutcomeOf box: OutcomeBox<Value>) async {
        await Waits.untilFirstEnds({ await flag.waitUntilSet() }, { await box.waitForOutcome() })
    }

    /// Whether `outcome` is a `CancellationError`.
    ///
    /// - Parameter outcome: The outcome of one submitter.
    /// - Returns: `true` for a `CancellationError`.
    private static func isCancellation<Value>(_ outcome: Result<Value, any Error>) -> Bool {
        guard case .failure(let error) = outcome else { return false }
        return error is CancellationError
    }

    /// Starts an item on `queue` that holds the worker until `release` is set,
    /// and waits until that item runs.
    ///
    /// - Parameters:
    ///   - queue: The queue.
    ///   - log: The log the item enters, as `"holder"`.
    ///   - release: The flag that ends the item.
    /// - Returns: The task of the submitter, and the box of its outcome.
    /// - Throws: An `ExpectationFailedError` when the item ended before it
    ///   ran.
    private static func startHolder(
        on queue: GenerationQueue, log: ItemLog, release: Flag
    ) async throws -> (task: Task<Void, Never>, box: OutcomeBox<String>) {
        let entered = Flag()
        let holder = submit(to: queue) {
            await log.enter("holder")
            entered.set()
            await waitUntilSet(release)
            await log.exit()
            return "holder"
        }
        await waitUntilSet(entered, orUntilOutcomeOf: holder.box)
        try #require(await log.started == ["holder"])
        return holder
    }

    /// Submits the item `name` to `queue`, and waits until the item is in the
    /// list. The `onQueued` of the submission tells when the item waits. An
    /// item that ends at once ends the wait too, and the check of the count
    /// then fails.
    ///
    /// - Parameters:
    ///   - name: The name of the item, which it also returns.
    ///   - queue: The queue.
    ///   - log: The log the item enters.
    ///   - waiting: The count of waiting items after this item joins.
    /// - Returns: The task of the submitter, and the box of its outcome.
    private static func submitWaiting(
        _ name: String, to queue: GenerationQueue, log: ItemLog, waiting: Int
    ) async -> (task: Task<Void, Never>, box: OutcomeBox<String>) {
        let queued = Flag()
        let item = submit(to: queue, onQueued: { queued.set() }) {
            await log.enter(name)
            await log.exit()
            return name
        }
        await waitUntilSet(queued, orUntilOutcomeOf: item.box)
        #expect(await queue.waitingCount == waiting)
        return item
    }

    @Test("items from three tasks run in FIFO order, one at a time, with no overlap")
    func itemsFromThreeTasksRunInOrderWithNoOverlap() async throws {
        let queue = GenerationQueue()
        let log = ItemLog()
        let release = Flag()
        let first = try await Self.startHolder(on: queue, log: log, release: release)
        let second = await Self.submitWaiting("second", to: queue, log: log, waiting: 1)
        let third = await Self.submitWaiting("third", to: queue, log: log, waiting: Self.itemsBehindTheFirst)
        let startedBeforeRelease = await log.started

        release.set()
        let answers = try await [
            Self.outcome(of: first.box, named: "the first result").get(),
            Self.outcome(of: second.box, named: "the second result").get(),
            Self.outcome(of: third.box, named: "the third result").get(),
        ]

        #expect(startedBeforeRelease == ["holder"])
        #expect(answers == ["holder", "second", "third"])
        #expect(await log.started == ["holder", "second", "third"])
        #expect(await log.peak == 1)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    @Test("an item submitted after the count shows the item before it runs after that item")
    func anItemSubmittedAfterTheCountShowsThePreviousItemRunsAfterIt() async throws {
        for _ in 0..<Self.orderRepetitions {
            let queue = GenerationQueue()
            let log = ItemLog()
            let release = Flag()
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            let names = (1...Self.itemsInLine).map { "item \($0)" }
            for (index, name) in names.enumerated() {
                _ = await Self.submitWaiting(name, to: queue, log: log, waiting: index + 1)
            }

            release.set()
            _ = try await Self.outcome(of: holder.box, named: "the holder result")
            // The queue is FIFO: when an item submitted after the line ends,
            // each item of the line ran.
            _ = try await queue.submit {}

            try #require(await log.started == ["holder"] + names)
        }
    }

    @Test("the result of an item is released at once when its submitter drops it")
    func theResultOfAnItemIsReleasedWhenItsSubmitterDropsIt() async throws {
        let queue = GenerationQueue()
        for _ in 0..<Self.releaseRepetitions {
            let released = Flag()
            var result: TrackedResult? = try await queue.submit { TrackedResult(released: released) }
            #expect(result != nil)

            result = nil

            try #require(released.isSet)
        }
    }

    @Test("a cancelled waiting item never runs, its submitter gets CancellationError at once, and the next item runs")
    func aCancelledWaitingItemNeverRunsAndTheNextItemRuns() async throws {
        let queue = GenerationQueue()
        let log = ItemLog()
        let release = Flag()
        let holder = try await Self.startHolder(on: queue, log: log, release: release)
        let cancelled = await Self.submitWaiting("cancelled", to: queue, log: log, waiting: 1)
        let next = await Self.submitWaiting("next", to: queue, log: log, waiting: Self.itemsBehindTheFirst)

        cancelled.task.cancel()
        let cancelledOutcome = try await Self.outcome(of: cancelled.box, named: "the cancelled result")
        let holderStillRuns = await queue.isRunning && holder.box.outcome == nil
        let waitingAfterCancel = await queue.waitingCount
        release.set()
        let nextAnswer = try await Self.outcome(of: next.box, named: "the next result").get()

        #expect(Self.isCancellation(cancelledOutcome))
        #expect(holderStillRuns)
        #expect(waitingAfterCancel == 1)
        #expect(nextAnswer == "next")
        #expect(await log.started == ["holder", "next"])
        #expect(await queue.isRunning == false)
    }

    @Test("a cancelled waiting item leaves the count of waiting items when the cancel returns")
    func aCancelledWaitingItemLeavesTheCountWhenTheCancelReturns() async throws {
        for _ in 0..<Self.raceRepetitions {
            let queue = GenerationQueue()
            let log = ItemLog()
            let release = Flag()
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            let cancelled = await Self.submitWaiting("cancelled", to: queue, log: log, waiting: 1)

            cancelled.task.cancel()
            let waitingAfterCancel = await queue.waitingCount
            release.set()
            let cancelledOutcome = try await Self.outcome(of: cancelled.box, named: "the cancelled result")
            _ = try await Self.outcome(of: holder.box, named: "the holder result")

            #expect(waitingAfterCancel == 0)
            #expect(Self.isCancellation(cancelledOutcome))
            #expect(await log.started == ["holder"])
        }
    }

    @Test("a cancelled running item gets the cancel on the task that runs it, and the next item runs")
    func aCancelledRunningItemGetsTheCancel() async throws {
        let queue = GenerationQueue()
        let log = ItemLog()
        let entered = Flag()
        let running = Self.submit(to: queue) {
            await log.enter("running")
            entered.set()
            while !Task.isCancelled {
                await Task.yield()
            }
            await log.exit()
            throw CancellationError()
        }
        await Self.waitUntilSet(entered, orUntilOutcomeOf: running.box)
        try #require(await log.started == ["running"])
        let next = await Self.submitWaiting("next", to: queue, log: log, waiting: 1)

        running.task.cancel()
        let runningOutcome = try await Self.outcome(of: running.box, named: "the cancelled running result")
        let nextAnswer = try await Self.outcome(of: next.box, named: "the next result").get()

        #expect(Self.isCancellation(runningOutcome))
        #expect(nextAnswer == "next")
        #expect(await log.started == ["running", "next"])
    }

    @Test("a cancel that races the start of an item resumes its submitter one time, and the queue runs the next item")
    func aCancelThatRacesTheStartOfAnItemResumesOneTime() async throws {
        for _ in 0..<Self.raceRepetitions {
            let queue = GenerationQueue()
            let log = ItemLog()
            let release = Flag()
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            let ran = Flag()
            let queued = Flag()
            let raced = Self.submit(to: queue, onQueued: { queued.set() }) {
                ran.set()
                return Self.racedValue
            }
            await Self.waitUntilSet(queued, orUntilOutcomeOf: raced.box)
            try #require(await queue.waitingCount == 1)

            release.set()
            raced.task.cancel()
            let racedOutcome = try await Self.outcome(of: raced.box, named: "the raced result")
            let next = Self.submit(to: queue) { Self.nextValue }
            let nextAnswer = try await Self.outcome(of: next.box, named: "the next result").get()
            _ = try await Self.outcome(of: holder.box, named: "the holder result")

            let ranAndAnswered = ran.isSet && (try? racedOutcome.get()) == Self.racedValue
            let refusedAndNeverRan = !ran.isSet && Self.isCancellation(racedOutcome)
            #expect(ranAndAnswered || refusedAndNeverRan)
            #expect(nextAnswer == Self.nextValue)
            #expect(await queue.isRunning == false)
            #expect(await queue.waitingCount == 0)
        }
    }

    @Test("a submitter that is cancelled before it submits gets CancellationError, and its item never runs")
    func anAlreadyCancelledSubmitterNeverRunsItsItem() async throws {
        let queue = GenerationQueue()
        let ran = Flag()
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.submit { ran.set() }
        }.result

        #expect(Self.isCancellation(outcome))
        #expect(!ran.isSet)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    @Test("a submission reports that it waits only when the worker runs another item")
    func aSubmissionReportsItsWaitOnlyWhenTheWorkerIsBusy() async throws {
        let queue = GenerationQueue()
        let entered = Flag()
        let release = Flag()
        let holderWaits = Flag()
        let waiterWaits = Flag()

        let holdingSubmission = Task {
            try await queue.submit(onQueued: { holderWaits.set() }) {
                entered.set()
                await Self.waitUntilSet(release)
            }
        }
        await Waits.untilFirstEnds({ await entered.waitUntilSet() }, { _ = await holdingSubmission.result })
        let holderInside = entered.isSet
        let waitingSubmission = Task {
            try await queue.submit(onQueued: { waiterWaits.set() }) {}
        }
        await Waits.untilFirstEnds({ await waiterWaits.waitUntilSet() }, { _ = await waitingSubmission.result })
        let waiterQueued = await queue.waitingCount == 1
        release.set()
        try await holdingSubmission.value
        try await waitingSubmission.value

        #expect(holderInside)
        #expect(waiterQueued)
        #expect(!holderWaits.isSet)
        #expect(waiterWaits.count == 1)
        #expect(await queue.isRunning == false)
    }

    /// The dimension values of the queue metrics, as the metrics backend of a
    /// consumer sees them, for a queue made with ``GenerationQueue/init()``.
    /// The shared ``QueueMetricExpectations`` reads and checks the metrics.
    private enum QueueMetric {
        /// The dimensions of a queue made with ``GenerationQueue/init()``,
        /// which has the queue name `generation`.
        static let queue = QueueMetricDimensions.queue(named: "generation")

        /// The outcome of a job that returned a value.
        static let succeeded = "succeeded"

        /// The outcome of a job whose body threw an error that is not
        /// `CancellationError`.
        static let failed = "failed"

        /// The outcome of a job that was cancelled.
        static let cancelled = "cancelled"
    }

    /// The error that the body of the failing job throws.
    private struct BodyError: Error {}

    /// The number of times the first job of the timing test yields while it
    /// runs.
    private static let yieldsInsideTheFirstJob = 10

    /// The number of nanoseconds in one second.
    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    /// The number of attoseconds in one nanosecond.
    private static let attosecondsPerNanosecond: Int64 = 1_000_000_000

    /// Gives `duration` in whole nanoseconds.
    ///
    /// - Parameter duration: The duration.
    /// - Returns: The nanoseconds of `duration`, with the remainder dropped.
    private static func nanoseconds(of duration: Duration) -> Int64 {
        duration.components.seconds * nanosecondsPerSecond
            + duration.components.attoseconds / attosecondsPerNanosecond
    }

    /// The number of jobs in the depth test: a holder and two waiting jobs.
    private static let threeJobs = 3

    /// The depth values of a holder and two waiting jobs: up for each job,
    /// then down for each job.
    private static let depthOfThreeJobs: [Double] = [1, 2, 3, 2, 1, 0]

    /// The depth values of one job.
    private static let depthOfOneJob: [Double] = [1, 0]

    /// The index of the first waiting job in the values of a timer. The
    /// holder completes first.
    private static let firstWaitingJob = 1

    /// The index of the second waiting job in the values of a timer.
    private static let secondWaitingJob = 2

    @Test("the second of two jobs in sequence waits at least the run time of the first job")
    func theSecondJobWaitsAtLeastTheRunTimeOfTheFirst() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()
        let log = ItemLog()
        let release = Flag()

        let firstBodyTime = try await withMetricsFactory(metrics) {
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            // The job measures its own body on the continuous clock of the
            // queue timers. The run timer starts before the body and stops
            // after it, thus the run time covers this measure, and the test
            // needs no clock wait to make the run time long.
            let firstQueued = Flag()
            let first = Self.submit(to: queue, onQueued: { firstQueued.set() }) {
                let start = ContinuousClock.now
                for _ in 0..<Self.yieldsInsideTheFirstJob {
                    await Task.yield()
                }
                return Self.nanoseconds(of: ContinuousClock.now - start)
            }
            await Self.waitUntilSet(firstQueued, orUntilOutcomeOf: first.box)
            try #require(await queue.waitingCount == 1)
            let second = await Self.submitWaiting("second", to: queue, log: log, waiting: Self.itemsBehindTheFirst)
            release.set()
            _ = try await Self.outcome(of: holder.box, named: "the holder result").get()
            let firstBodyTime = try await Self.outcome(of: first.box, named: "the first result").get()
            _ = try await Self.outcome(of: second.box, named: "the second result").get()
            return firstBodyTime
        }

        let wait = try QueueMetricExpectations.waitTimes(
            in: metrics, queue: QueueMetric.queue, outcome: QueueMetric.succeeded)
        let run = try QueueMetricExpectations.runTimes(in: metrics, queue: QueueMetric.queue, outcome: QueueMetric.succeeded)
        try #require(wait.count == Self.secondWaitingJob + 1 && run.count == Self.secondWaitingJob + 1)
        #expect(run[Self.firstWaitingJob] >= firstBodyTime)
        #expect(wait[Self.secondWaitingJob] >= run[Self.firstWaitingJob])
    }

    @Test("the depth goes up for each job that waits or runs, and goes back to 0 when the queue is idle")
    func theDepthCountsEachJobAndGoesBackToZero() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()
        let log = ItemLog()
        let release = Flag()

        try await withMetricsFactory(metrics) {
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            let second = await Self.submitWaiting("second", to: queue, log: log, waiting: 1)
            let third = await Self.submitWaiting("third", to: queue, log: log, waiting: Self.itemsBehindTheFirst)
            release.set()
            _ = try await Self.outcome(of: holder.box, named: "the holder result").get()
            _ = try await Self.outcome(of: second.box, named: "the second result").get()
            _ = try await Self.outcome(of: third.box, named: "the third result").get()
        }

        #expect(try QueueMetricExpectations.depth(in: metrics, queue: QueueMetric.queue) == Self.depthOfThreeJobs)
        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: QueueMetric.queue, outcome: QueueMetric.succeeded, ran: true, count: Self.threeJobs)
    }

    @Test("a waiting job that is cancelled records cancelled, a wait time and no run time")
    func aCancelledWaitingJobRecordsNoRunTime() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()
        let log = ItemLog()
        let release = Flag()

        try await withMetricsFactory(metrics) {
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            let cancelled = await Self.submitWaiting("cancelled", to: queue, log: log, waiting: 1)
            cancelled.task.cancel()
            #expect(Self.isCancellation(try await Self.outcome(of: cancelled.box, named: "the cancelled result")))
            release.set()
            _ = try await Self.outcome(of: holder.box, named: "the holder result").get()
        }

        // The holder also completes, as a job that ran and succeeded.
        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: QueueMetric.queue,
            [
                .init(outcome: QueueMetric.cancelled, ran: false),
                .init(outcome: QueueMetric.succeeded, ran: true),
            ])
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: QueueMetric.queue).last == 0)
    }

    @Test("a running job that is cancelled records its run time and cancelled when its body throws CancellationError")
    func aCancelledRunningJobRecordsItsRunTime() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()
        let log = ItemLog()

        let outcome = try await withMetricsFactory(metrics) {
            let entered = Flag()
            let running = Self.submit(to: queue) {
                await log.enter("running")
                entered.set()
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
            await Self.waitUntilSet(entered, orUntilOutcomeOf: running.box)
            try #require(await log.started == ["running"])
            running.task.cancel()
            return try await Self.outcome(of: running.box, named: "the running result")
        }

        #expect(Self.isCancellation(outcome))
        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: QueueMetric.queue, outcome: QueueMetric.cancelled, ran: true)
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: QueueMetric.queue) == Self.depthOfOneJob)
    }

    @Test("a job whose body throws an error that is not CancellationError records failed")
    func aJobWhoseBodyThrowsRecordsFailed() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()

        let outcome = await withMetricsFactory(metrics) {
            await Task { try await queue.submit { throw BodyError() } }.result
        }

        #expect(throws: BodyError.self) { try outcome.get() }
        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: QueueMetric.queue, outcome: QueueMetric.failed, ran: true)
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: QueueMetric.queue) == Self.depthOfOneJob)
    }

    @Test("a job of a submitter that is cancelled before it submits records cancelled, no run time and no depth")
    func aJobOfAnAlreadyCancelledSubmitterRecordsCancelled() async throws {
        let metrics = TestMetrics()
        let queue = GenerationQueue()

        let outcome = await withMetricsFactory(metrics) {
            await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await queue.submit {}
            }.result
        }

        #expect(Self.isCancellation(outcome))
        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: QueueMetric.queue, outcome: QueueMetric.cancelled, ran: false)
        // The queue never accepted the job, thus the depth never went up.
        #expect(throws: TestMetricsError.self) {
            try QueueMetricExpectations.depth(in: metrics, queue: QueueMetric.queue)
        }
    }

    /// The model the marks of the refusal tests name.
    private static let markedModel: ModelRef = "org/marked-model"

    /// Submits an item that sets `ran` to `queue`, under `mark`, and gives its
    /// outcome.
    ///
    /// - Parameters:
    ///   - queue: The queue to submit to.
    ///   - mark: The model-call mark of the submitting task.
    ///   - ran: The flag the item sets when it runs.
    /// - Returns: The outcome of the submission.
    private static func submitUnderMark(
        to queue: GenerationQueue, mark: ModelCallMark, ran: Flag
    ) async -> Result<Int, any Error> {
        await ModelCallMark.$current.withValue(mark) {
            do {
                return .success(
                    try await queue.submit {
                        ran.set()
                        return Self.racedValue
                    })
            } catch {
                return .failure(error)
            }
        }
    }

    @Test("a submission from a task inside an open submission on the same queue is refused at once, and never runs")
    func aSubmissionInsideAnOpenSubmissionOnTheSameQueueIsRefused() async throws {
        let queue = GenerationQueue()
        let ran = Flag()
        let mark = ModelCallMark(
            sessionID: ULID(), submission: SubmissionTarget(queue: queue, model: Self.markedModel))

        let outcome = await Self.submitUnderMark(to: queue, mark: mark, ran: ran)

        #expect(throws: GenerationQueueError.waitInsideOpenSubmission(model: Self.markedModel)) {
            try outcome.get()
        }
        #expect(!ran.isSet)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    @Test("a submission under a closed mark, or an open mark of another queue, runs")
    func aSubmissionOutsideAnOpenSubmissionOnItsQueueRuns() async throws {
        let queue = GenerationQueue()
        let otherQueue = GenerationQueue()
        let closed = ModelCallMark(
            sessionID: ULID(), submission: SubmissionTarget(queue: queue, model: Self.markedModel))
        closed.close()
        let otherModel = ModelCallMark(
            sessionID: ULID(), submission: SubmissionTarget(queue: otherQueue, model: Self.markedModel))
        let ranUnderClosed = Flag()
        let ranUnderOther = Flag()

        let closedOutcome = await Self.submitUnderMark(to: queue, mark: closed, ran: ranUnderClosed)
        let otherOutcome = await Self.submitUnderMark(to: queue, mark: otherModel, ran: ranUnderOther)

        #expect(try closedOutcome.get() == Self.racedValue)
        #expect(try otherOutcome.get() == Self.racedValue)
        #expect(ranUnderClosed.isSet)
        #expect(ranUnderOther.isSet)
    }

    @Test("a background run of an open submission is not refused a submission on the same queue")
    func aBackgroundRunOfAnOpenSubmissionIsNotRefused() async throws {
        let queue = GenerationQueue()
        let ran = Flag()
        let open = ModelCallMark(
            sessionID: ULID(), submission: SubmissionTarget(queue: queue, model: Self.markedModel))

        let outcome = await ModelCallMark.$current.withValue(open) {
            await ModelCallMark.withBackgroundRunMark {
                await Self.submitUnderMark(to: queue, mark: ModelCallMark.current ?? open, ran: ran)
            }
        }

        #expect(try outcome.get() == Self.racedValue)
        #expect(ran.isSet)
    }
}

/// An item runs on a task that the worker makes, which inherits no task-local
/// of its submitter. The item restores only the telemetry of its submitter:
/// the trace context, the tracer and the metrics factory.
@Suite("Generation queue: an item runs on the worker task")
struct GenerationQueueWorkerTaskTests {
    /// The task-local that the test binds around the submission.
    private enum SubmitterMark {
        /// The mark of the task that submits, or `nil` when no caller bound
        /// one.
        @TaskLocal static var value: String?
    }

    /// The mark the test binds around each submission.
    private static let submitterMark = "submitter"

    @Test("with no queue, a child task sees the task-local of its caller (the control)")
    func aChildTaskSeesTheCallerTaskLocal() async {
        let seen = await SubmitterMark.$value.withValue(Self.submitterMark) {
            await Task { SubmitterMark.value }.value
        }

        #expect(seen == Self.submitterMark)
    }

    @Test("an item submitted to the queue runs on the worker task, and sees no task-local of its submitter")
    func anItemRunsOnTheWorkerTask() async throws {
        let queue = GenerationQueue()

        let seen = try await SubmitterMark.$value.withValue(Self.submitterMark) {
            try await queue.submit { SubmitterMark.value }
        }

        #expect(seen == nil)
        #expect(await queue.isRunning == false)
    }

    /// The name of the span that the submitter opens around a submission.
    private static let submitterSpanName = "probe.submitter"

    /// The name of the span that a job body opens.
    private static let jobSpanName = "probe.job"

    /// The label of the counter that a job body increments.
    private static let jobCounterLabel = "probe.job.counter"

    /// The count that one increment adds to a counter.
    private static let oneIncrement: Int64 = 1

    /// Opens the submitter span, and in it submits a job that opens the job
    /// span and increments the job counter. The global tracer and the global
    /// metrics factory of the task give the span and the counter.
    ///
    /// - Parameter queue: The queue to submit to.
    /// - Throws: The error of the submission.
    private static func submitTracedJob(to queue: GenerationQueue) async throws {
        try await withSpan(submitterSpanName) { _ in
            try await queue.submit {
                withSpan(jobSpanName) { _ in
                    Metrics.Counter(label: jobCounterLabel).increment()
                }
            }
        }
    }

    @Test("a span that a job body opens has the span of the submitter as its parent, in the same trace")
    func aJobSpanHasTheSubmitterSpanAsItsParent() async throws {
        let queue = GenerationQueue()
        let tracer = W3CInMemoryTracer()

        try await withTracer(tracer) {
            try await Self.submitTracedJob(to: queue)
        }

        let spans = tracer.finishedSpans
        let submitter = try #require(spans.first { $0.operationName == Self.submitterSpanName })
        let job = try #require(spans.first { $0.operationName == Self.jobSpanName })
        #expect(job.parentSpanID == submitter.spanID)
        #expect(job.traceID == submitter.traceID)
    }

    @Test("a metric that a job body records reaches the metrics factory that the submitter binds")
    func aJobMetricReachesTheFactoryOfTheSubmitter() async throws {
        let queue = GenerationQueue()
        let metrics = TestMetrics()

        try await withMetricsFactory(metrics) {
            try await Self.submitTracedJob(to: queue)
        }

        #expect(try metrics.expectCounter(Self.jobCounterLabel).values == [Self.oneIncrement])
    }

    @Test("a capture sees the span and the metric that a job body writes")
    func aCaptureSeesTheSpanAndTheMetricOfAJob() async throws {
        let queue = GenerationQueue()

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            try await Self.submitTracedJob(to: queue)
            return context
        }

        #expect(context.spans.contains { $0.operationName == Self.jobSpanName })
        #expect(context.metricRecords.contains { $0.label == Self.jobCounterLabel })
    }

    @Test("a job body sees no ModelCallMark of its submitter, also when the submitter binds a tracer and a span")
    func aJobSeesNoModelCallMarkOfItsSubmitter() async throws {
        let queue = GenerationQueue()
        let mark = ModelCallMark(sessionID: ULID())

        let markInJob = try await withTracer(W3CInMemoryTracer()) {
            try await withSpan(Self.submitterSpanName) { _ in
                try await ModelCallMark.$current.withValue(mark) {
                    try await queue.submit { ModelCallMark.current }
                }
            }
        }

        #expect(markInJob == nil)
    }
}
