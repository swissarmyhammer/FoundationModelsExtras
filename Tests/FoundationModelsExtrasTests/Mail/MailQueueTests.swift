@testable import FoundationModelsExtras
import Metrics
import MetricsTestKit
import Synchronization
import Testing
import ULID

/// Makes a user message mail with `prompt` as its text.
///
/// - Parameter prompt: The text of the message.
/// - Returns: The mail, with a new id.
private func userMail(_ prompt: String) -> Mail {
    Mail(sender: .user, body: .userMessage(prompt: prompt, options: UserMessageOptions()))
}

/// Gives the text of each user message of `mails`.
///
/// - Parameter mails: The mail.
/// - Returns: The prompt of each user message, in order. Other mail gives
///   no text.
private func prompts(_ mails: [Mail]) -> [String] {
    mails.compactMap { mail in
        if case .userMessage(let prompt, _) = mail.body { return prompt }
        return nil
    }
}

/// A take rule that takes each mail.
private let takeAll: @Sendable (Mail, [Mail]) -> Bool = { _, _ in true }

/// ``MailQueue`` keeps mail in FIFO order, takes it with a rule, and
/// supports cancel, replace, put back, pause, drain and close.
@Suite("MailQueue: put, take with a rule, cancel, replace, put back, pause, drain and close")
struct MailQueueTests {
    @Test("a take of all mail gives the mail in the order of the puts")
    func theQueueIsFIFO() throws {
        let queue = MailQueue()
        for prompt in ["a", "b", "c"] {
            try queue.put(userMail(prompt))
        }

        #expect(prompts(queue.take(admitting: takeAll)) == ["a", "b", "c"])
        #expect(queue.pending.isEmpty)
    }

    @Test("a rule that skips mail leaves that mail in the queue, in its order")
    func aSkipKeepsTheOrderOfTheMailThatIsLeft() throws {
        let queue = MailQueue()
        for prompt in ["a", "skip1", "b", "skip2", "c"] {
            try queue.put(userMail(prompt))
        }

        let taken = queue.take { candidate, _ in !prompts([candidate])[0].hasPrefix("skip") }

        #expect(prompts(taken) == ["a", "b", "c"])
        #expect(prompts(queue.pending) == ["skip1", "skip2"])
    }

    @Test("the rule gets the batch that the take made before the candidate")
    func theRuleGetsTheBatchSoFar() throws {
        let queue = MailQueue()
        for prompt in ["a", "b", "c"] {
            try queue.put(userMail(prompt))
        }

        let taken = queue.take { _, batch in batch.count < 2 }

        #expect(prompts(taken) == ["a", "b"])
        #expect(prompts(queue.pending) == ["c"])
    }

    @Test("a take while the queue is paused gives no mail, and a resume opens the queue again")
    func aPauseStopsTheTake() throws {
        let queue = MailQueue()
        try queue.put(userMail("a"))

        queue.pause()
        #expect(queue.take(admitting: takeAll).isEmpty)
        #expect(prompts(queue.pending) == ["a"])

        queue.resume()
        #expect(prompts(queue.take(admitting: takeAll)) == ["a"])
    }

    @Test("two pauses need two resumes, and a resume with no pause does nothing")
    func pausesAreACounter() throws {
        let queue = MailQueue()
        queue.resume()
        try queue.put(userMail("a"))

        queue.pause()
        queue.pause()
        queue.resume()
        #expect(queue.take(admitting: takeAll).isEmpty)

        queue.resume()
        #expect(prompts(queue.take(admitting: takeAll)) == ["a"])
    }

    @Test("put, cancel and replace work while the queue is paused")
    func editsWorkWhilePaused() throws {
        let queue = MailQueue()
        queue.pause()
        let first = userMail("a")
        let second = userMail("b")
        try queue.put(first)
        try queue.put(second)

        #expect(queue.cancel(first.id) == first)
        #expect(queue.replace(second.id, with: .userMessage(prompt: "B", options: UserMessageOptions())))
        #expect(prompts(queue.pending) == ["B"])
    }

    @Test("a put of an id that is in the queue throws duplicateID")
    func aDuplicatePutThrows() throws {
        let queue = MailQueue()
        let mail = userMail("a")
        try queue.put(mail)

        #expect(throws: MailRefusal.duplicateID(mail.id)) {
            try queue.put(mail)
        }
        #expect(queue.pending.count == 1)
    }

    @Test("a put after close throws closed")
    func aPutAfterCloseThrows() throws {
        let queue = MailQueue()
        queue.close()

        #expect(throws: MailRefusal.closed) {
            try queue.put(userMail("a"))
        }
    }

    @Test("a cancel removes and gives the queued mail, and gives nil for an id that is not in the queue")
    func aCancelRemovesTheMail() throws {
        let queue = MailQueue()
        let first = userMail("a")
        try queue.put(first)
        try queue.put(userMail("b"))

        #expect(queue.cancel(first.id) == first)
        #expect(prompts(queue.pending) == ["b"])
        #expect(queue.cancel(first.id) == nil)
        #expect(queue.cancel(MailID()) == nil)
    }

    @Test("a cancel does not touch mail that a take removed")
    func aCancelDoesNotTouchTakenMail() throws {
        let queue = MailQueue()
        let mail = userMail("a")
        try queue.put(mail)
        _ = queue.take(admitting: takeAll)

        #expect(queue.cancel(mail.id) == nil)
    }

    @Test("a replace changes only the body, and the id, the sender and the place stay the same")
    func aReplaceChangesTheBody() throws {
        let queue = MailQueue()
        let sender = MailSender.session(ULID())
        let middle = Mail(sender: sender, body: .agentMessage(from: ULID(), content: "old"))
        try queue.put(userMail("a"))
        try queue.put(middle)
        try queue.put(userMail("c"))
        let body = MailBody.agentMessage(from: ULID(), content: "new")

        #expect(queue.replace(middle.id, with: body))

        let replaced = queue.pending[1]
        #expect(replaced.id == middle.id)
        #expect(replaced.sender == sender)
        #expect(replaced.body == body)
        #expect(queue.pending.count == 3)
    }

    @Test("a replace of an id that is not in the queue gives false")
    func aReplaceOfAMissingIDGivesFalse() {
        let queue = MailQueue()

        #expect(!queue.replace(MailID(), with: .userMessage(prompt: "x", options: UserMessageOptions())))
    }

    @Test("a put back puts the mail at the front, in the given order")
    func aPutBackGoesToTheFront() throws {
        let queue = MailQueue()
        try queue.put(userMail("c"))

        queue.putBack([userMail("a"), userMail("b")])

        #expect(prompts(queue.pending) == ["a", "b", "c"])
    }

    @Test("a drain gives the mail in order, and the queue stays open")
    func aDrainGivesTheMailInOrder() throws {
        let queue = MailQueue()
        try queue.put(userMail("a"))
        try queue.put(userMail("b"))

        #expect(prompts(queue.drain()) == ["a", "b"])
        #expect(queue.pending.isEmpty)
        try queue.put(userMail("c"))
        #expect(prompts(queue.pending) == ["c"])
    }

    @Test("a close gives the mail in order")
    func aCloseGivesTheMailInOrder() throws {
        let queue = MailQueue()
        try queue.put(userMail("a"))
        try queue.put(userMail("b"))

        #expect(prompts(queue.close()) == ["a", "b"])
        #expect(queue.pending.isEmpty)
    }

    @Test("depthByKind counts the queued mail of each kind")
    func depthByKindCountsEachKind() throws {
        let queue = MailQueue()
        try queue.put(userMail("a"))
        try queue.put(userMail("b"))
        try queue.put(Mail(sender: .session(ULID()), body: .agentMessage(from: ULID(), content: "c")))

        #expect(queue.depthByKind == [.userMessage: 2, .agentMessage: 1])
        _ = queue.drain()
        #expect(queue.depthByKind.isEmpty)
    }
}

/// ``MailQueue/waitForMail()`` returns when the queue is open and holds
/// mail, or when the queue is closed.
@Suite("MailQueue: the wait for mail")
struct MailQueueWaitTests {
    /// Starts a task that waits for mail, and waits until the queue sees it.
    ///
    /// - Parameter queue: The queue.
    /// - Returns: The task of the waiter, and a flag that is set when the
    ///   wait returns.
    private static func startWaiter(on queue: MailQueue) async -> (task: Task<Void, Never>, returned: ReturnFlag) {
        let returned = ReturnFlag()
        let task = Task {
            await queue.waitForMail()
            returned.set()
        }
        #expect(await BoundedWait.conditionReached("the waiter waits") { queue.waiterCount == 1 })
        return (task, returned)
    }

    @Test("the wait returns at once when the queue holds mail")
    func theWaitReturnsAtOnce() async throws {
        let queue = MailQueue()
        try queue.put(userMail("a"))

        await queue.waitForMail()

        #expect(queue.waiterCount == 0)
    }

    @Test("the wait returns at a put")
    func theWaitReturnsAtAPut() async throws {
        let queue = MailQueue()
        let waiter = await Self.startWaiter(on: queue)

        try queue.put(userMail("a"))

        await waiter.task.value
        #expect(waiter.returned.isSet)
        #expect(queue.waiterCount == 0)
    }

    @Test("the wait does not return at a put while the queue is paused, and returns at the resume")
    func theWaitReturnsAtTheResume() async throws {
        let queue = MailQueue()
        queue.pause()
        let waiter = await Self.startWaiter(on: queue)

        try queue.put(userMail("a"))
        #expect(queue.waiterCount == 1)
        #expect(!waiter.returned.isSet)

        queue.resume()

        await waiter.task.value
        #expect(waiter.returned.isSet)
    }

    @Test("the wait returns at a close")
    func theWaitReturnsAtAClose() async {
        let queue = MailQueue()
        let waiter = await Self.startWaiter(on: queue)

        queue.close()

        await waiter.task.value
        #expect(waiter.returned.isSet)
    }

    @Test("the wait returns when its task is cancelled, and the queue forgets the waiter")
    func theWaitReturnsAtACancel() async {
        let queue = MailQueue()
        let waiter = await Self.startWaiter(on: queue)

        waiter.task.cancel()

        await waiter.task.value
        #expect(await BoundedWait.conditionReached("the queue forgets the waiter") { queue.waiterCount == 0 })
    }
}

/// Exercises the queue metrics of ``MailQueue``: each mail is one queue task
/// with the queue name `mail_queue`. The depth goes up at a put and down when
/// the mail leaves the queue. A take records `succeeded` with no run time. A
/// cancel and a drain record `cancelled`.
@Suite("MailQueue: the queue metrics of each mail")
struct MailQueueTelemetryTests {
    /// The value of the queue name dimension of each mail queue.
    private static let queueName = "mail_queue"

    /// The model that a mail queue of the tests with a model belongs to.
    private static let model: ModelRef = "org/mail-queue-model"

    /// The depth values of one mail: up at the put, then down when it leaves.
    private static let depthOfOneMail: [Double] = [1, 0]

    /// The depth values of two mail that leave together.
    private static let depthOfTwoMail: [Double] = [1, 2, 1, 0]

    /// Gives the dimensions of the depth meter of a mail queue.
    ///
    /// - Parameter model: The model of the queue, or `nil` for no model.
    /// - Returns: The queue name `mail_queue`, then the model ref when set.
    private static func queueDimensions(model: ModelRef? = nil) -> [(String, String)] {
        QueueMetricDimensions.queue(named: queueName, model: model?.stringValue)
    }

    @Test("a taken mail records succeeded, a wait time, no run time and one count, and the depth goes back to 0")
    func aTakenMailRecordsSucceeded() throws {
        let metrics = TestMetrics()
        let queue = MailQueue()

        try withMetricsFactory(metrics) {
            try queue.put(userMail("a"))
            _ = queue.take(admitting: takeAll)
        }

        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: Self.queueDimensions(), outcome: .succeeded, ran: false)
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: Self.queueDimensions()) == Self.depthOfOneMail)
    }

    @Test("a cancelled mail records cancelled")
    func aCancelledMailRecordsCancelled() throws {
        let metrics = TestMetrics()
        let queue = MailQueue()

        try withMetricsFactory(metrics) {
            let mail = userMail("a")
            try queue.put(mail)
            queue.cancel(mail.id)
        }

        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: Self.queueDimensions(), outcome: .cancelled, ran: false)
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: Self.queueDimensions()) == Self.depthOfOneMail)
    }

    @Test("a drain records cancelled for each mail")
    func aDrainRecordsCancelled() throws {
        let metrics = TestMetrics()
        let queue = MailQueue()

        try withMetricsFactory(metrics) {
            try queue.put(userMail("a"))
            try queue.put(userMail("b"))
            queue.drain()
        }

        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: Self.queueDimensions(), outcome: .cancelled, ran: false, count: 2)
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: Self.queueDimensions()) == Self.depthOfTwoMail)
    }

    @Test("a refused put records no metric")
    func aRefusedPutRecordsNothing() throws {
        let metrics = TestMetrics()
        let queue = MailQueue()

        try withMetricsFactory(metrics) {
            let mail = userMail("a")
            try queue.put(mail)
            #expect(throws: MailRefusal.duplicateID(mail.id)) { try queue.put(mail) }
        }

        #expect(try QueueMetricExpectations.depth(in: metrics, queue: Self.queueDimensions()) == [1])
    }

    @Test("a mail queue made with a model records the model ref dimension")
    func aQueueWithAModelRecordsTheModelRef() throws {
        let metrics = TestMetrics()
        let queue = MailQueue(model: Self.model)

        try withMetricsFactory(metrics) {
            try queue.put(userMail("a"))
            _ = queue.take(admitting: takeAll)
        }

        let dimensions = Self.queueDimensions(model: Self.model)
        try QueueMetricExpectations.expectCompletedJobs(in: metrics, queue: dimensions, outcome: .succeeded, ran: false)
        #expect(try QueueMetricExpectations.depth(in: metrics, queue: dimensions) == Self.depthOfOneMail)
    }
}

/// A flag that a waiter task sets when its wait returns.
private final class ReturnFlag: Sendable {
    /// Whether the wait returned.
    private let value = Mutex(false)

    /// Whether the wait returned.
    var isSet: Bool { value.withLock { $0 } }

    /// Records that the wait returned.
    func set() { value.withLock { $0 = true } }
}
