import FoundationModelsExtras
import Synchronization
import Testing
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

    /// Keeps the outcome of one submitter, so a test reads it inside a bound
    /// instead of an `await` that can hang.
    private final class OutcomeBox<Value: Sendable>: Sendable {
        /// The outcome, or `nil` while the submitter waits.
        private let stored = Mutex<Result<Value, any Error>?>(nil)

        /// The outcome, or `nil` while the submitter waits.
        var outcome: Result<Value, any Error>? { stored.withLock { $0 } }

        /// Keeps `outcome`.
        ///
        /// - Parameter outcome: The outcome of the submitter.
        func store(_ outcome: Result<Value, any Error>) {
            stored.withLock { $0 = outcome }
        }
    }

    /// A flag that a test or an item sets, and the number of times it was set.
    private final class Flag: Sendable {
        /// The number of times the flag was set.
        private let setCount = Atomic<Int>(0)

        /// The number of times the flag was set.
        var count: Int { setCount.load(ordering: .sequentiallyConsistent) }

        /// Whether the flag was set.
        var isSet: Bool { count > 0 }

        /// Sets the flag.
        func set() {
            setCount.add(1, ordering: .sequentiallyConsistent)
        }
    }

    /// The time between two readings of a flag that an item waits for.
    private static let flagPollNanoseconds: UInt64 = 1_000_000

    /// Waits until `flag` is set.
    ///
    /// - Parameter flag: The flag to wait for.
    private static func waitUntilSet(_ flag: Flag) async {
        while !flag.isSet {
            try? await Task.sleep(nanoseconds: flagPollNanoseconds)
        }
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
    ///   - body: The item.
    /// - Returns: The task of the submitter, and the box of its outcome.
    private static func submit<Value: Sendable>(
        to queue: GenerationQueue, _ body: @escaping @Sendable () async throws -> Value
    ) -> (task: Task<Void, Never>, box: OutcomeBox<Value>) {
        let box = OutcomeBox<Value>()
        let task = Task {
            let outcome: Result<Value, any Error>
            do {
                outcome = .success(try await queue.submit(body))
            } catch {
                outcome = .failure(error)
            }
            box.store(outcome)
        }
        return (task, box)
    }

    /// Waits inside the bound until `box` holds an outcome.
    ///
    /// - Parameters:
    ///   - box: The box of one submitter.
    ///   - label: What the outcome means, named in the recorded issue.
    /// - Returns: The outcome.
    /// - Throws: An `ExpectationFailedError` when no outcome came inside the
    ///   bound.
    private static func outcome<Value: Sendable>(
        of box: OutcomeBox<Value>, named label: String
    ) async throws -> Result<Value, any Error> {
        _ = await BoundedWait.conditionReached(label) { box.outcome != nil }
        return try #require(box.outcome)
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
    /// - Throws: An `ExpectationFailedError` when the item never ran.
    private static func startHolder(
        on queue: GenerationQueue, log: ItemLog, release: Flag
    ) async throws -> (task: Task<Void, Never>, box: OutcomeBox<String>) {
        let holder = submit(to: queue) {
            await log.enter("holder")
            await waitUntilSet(release)
            await log.exit()
            return "holder"
        }
        try #require(await BoundedWait.conditionReached("the holding item runs") { await log.started == ["holder"] })
        return holder
    }

    /// Submits the item `name` to `queue`, and waits until the list holds
    /// `waiting` items.
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
        let item = submit(to: queue) {
            await log.enter(name)
            await log.exit()
            return name
        }
        _ = await BoundedWait.conditionReached("the item \(name) waits") { await queue.waitingCount == waiting }
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
            try #require(
                await BoundedWait.conditionReached("every item in the line runs") {
                    await log.started.count == names.count + 1
                })

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
        let running = Self.submit(to: queue) {
            await log.enter("running")
            while !Task.isCancelled {
                await Task.yield()
            }
            await log.exit()
            throw CancellationError()
        }
        _ = await BoundedWait.conditionReached("the item runs") { await log.started == ["running"] }
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
            let raced = Self.submit(to: queue) {
                ran.set()
                return Self.racedValue
            }
            _ = await BoundedWait.conditionReached("the raced item waits") { await queue.waitingCount == 1 }

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
        let holderInside = await BoundedWait.conditionReached("the holding submission started") { entered.isSet }
        let waitingSubmission = Task {
            try await queue.submit(onQueued: { waiterWaits.set() }) {}
        }
        let waiterQueued = await BoundedWait.conditionReached("the second submission waited for the worker") {
            await queue.waitingCount == 1
        }
        release.set()
        try await holdingSubmission.value
        try await waitingSubmission.value

        #expect(holderInside)
        #expect(waiterQueued)
        #expect(!holderWaits.isSet)
        #expect(waiterWaits.count == 1)
        #expect(await queue.isRunning == false)
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
/// of its submitter.
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
}
