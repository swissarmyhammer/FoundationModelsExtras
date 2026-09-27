@testable import FoundationModelsExtras
import Testing

/// The mailbox of the tests: text messages, and text answers.
private typealias TestMailbox = Mailbox<String, String>

/// A pump for the tests. It takes each batch from a mailbox, records the
/// messages of the batch, and holds the batch until the test releases it.
private struct TestPump {
    /// The messages of each batch that the pump took, in order.
    let batches: Recorder<[String]>

    /// The messages of each batch whose body ran to its end, in order.
    let finished: Recorder<[String]>

    /// Each value releases one held batch.
    private let releases: AsyncStream<Void>.Continuation

    /// The task of the pump.
    private let task: Task<Void, Never>

    /// Starts a pump on `mailbox`.
    ///
    /// - Parameters:
    ///   - mailbox: The mailbox.
    ///   - holding: Whether the pump holds each batch until ``release()``.
    ///   - joins: The joining rule of each batch.
    init(
        _ mailbox: TestMailbox, holding: Bool = true,
        joining joins: @escaping @Sendable (String, String) -> Bool = { _, _ in true }
    ) {
        let batches = Recorder<[String]>()
        let finished = Recorder<[String]>()
        let (held, releases) = AsyncStream.makeStream(of: Void.self)
        self.batches = batches
        self.finished = finished
        self.releases = releases
        task = Task {
            while await mailbox.answerNextBatch(
                joining: joins,
                { letters in
                    let messages = letters.map(\.message)
                    batches.append(messages)
                    if holding {
                        for await _ in held { break }
                    }
                    try Task.checkCancellation()
                    finished.append(messages)
                    return Self.answer(to: messages)
                })
            {}
        }
    }

    /// The answer of the pump to a batch of `messages`.
    ///
    /// - Parameter messages: The messages of the batch.
    /// - Returns: The answer.
    static func answer(to messages: [String]) -> String {
        "answer to " + messages.joined(separator: ", ")
    }

    /// Releases one held batch.
    func release() {
        releases.yield()
    }

    /// Waits until the pump took `count` batches.
    ///
    /// - Parameter count: The number of batches.
    /// - Throws: An `ExpectationFailedError` when the pump did not take them.
    func waitForBatches(_ count: Int) async throws {
        try #require(await BoundedWait.conditionReached("the pump takes \(count) batches") { batches.values.count == count })
    }

    /// Waits until the body of `count` batches ran to its end.
    ///
    /// - Parameter count: The number of batches.
    /// - Throws: An `ExpectationFailedError` when the bodies did not end.
    func waitForFinished(_ count: Int) async throws {
        try #require(await BoundedWait.conditionReached("\(count) batches end") { finished.values.count == count })
    }

    /// Cancels the pump, and waits for its end.
    func stop() async {
        task.cancel()
        await task.value
    }
}

/// Exercises ``Mailbox``: ``Mailbox/post(_:)``, ``Mailbox/pending``,
/// ``Mailbox/replace(_:with:)``, ``Mailbox/depth`` and ``Mailbox/cancel(_:)``,
/// against the point where the pump takes a message for its batch.
@Suite("Mailbox: post, inspect, edit, cancel, and the batches of the pump")
struct MailboxTests {
    // MARK: - FIFO order

    @Test("messages posted while a batch runs come together in the next batch, in the order they were posted")
    func postedMessagesReachThePumpInFIFOOrder() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        mailbox.post("first")
        try await pump.waitForBatches(1)
        mailbox.post("second")
        mailbox.post("third")
        pump.release()
        try await pump.waitForBatches(2)
        pump.release()
        try await pump.waitForFinished(2)
        await pump.stop()

        #expect(pump.batches.values == [["first"], ["second", "third"]])
    }

    @Test("post returns its id while the batch of the message still runs")
    func postReturnsBeforeItsAnswer() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let (id, answer) = mailbox.post("wake the pump")
        try await pump.waitForBatches(1)
        #expect(mailbox.depth.running == [id])

        pump.release()
        #expect(try await answer.value == TestPump.answer(to: ["wake the pump"]))
        await pump.stop()
    }

    @Test("a postAndWait and a message posted before it each reach a batch once, in the order they arrived")
    func postAndWaitAndPostedMessageKeepTheirOrder() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox, holding: false)

        mailbox.post("queued")
        let reply = try await mailbox.postAndWait("direct")
        await pump.stop()

        // The pump can carry both in one batch, or one in each; either way
        // each message reaches the pump once, and the posted one first.
        #expect(pump.batches.values.flatMap(\.self) == ["queued", "direct"])
        #expect(reply.hasSuffix("direct"))
        #expect(mailbox.pending.isEmpty)
    }

    // MARK: - pending: post, replace, cancel

    @Test(
        "pending reflects post, replace and cancel; a withdrawn message never reaches a batch; a replaced message delivers its new content"
    )
    func pendingReflectsPostReplaceCancel() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let blocking = Task { try await mailbox.postAndWait("blocking message") }
        try await pump.waitForBatches(1)
        let firstId = mailbox.post("cancel me").id
        let secondId = mailbox.post("original").id
        #expect(mailbox.pending.map(\.message) == ["cancel me", "original"])

        #expect(mailbox.cancel(firstId) == .withdrawn)
        #expect(mailbox.pending.map(\.id) == [secondId])

        #expect(mailbox.replace(secondId, with: "edited") == .applied)
        #expect(mailbox.pending.map(\.message) == ["edited"])

        pump.release()
        _ = try await blocking.value
        try await pump.waitForBatches(2)
        pump.release()
        try await pump.waitForFinished(2)
        await pump.stop()

        #expect(pump.batches.values == [["blocking message"], ["edited"]])
        #expect(mailbox.pending.isEmpty)
    }

    @Test("a message withdrawn before its batch leaves no trace in any batch")
    func withdrawnMessageLeavesNoTrace() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let blocking = Task { try await mailbox.postAndWait("blocking message") }
        try await pump.waitForBatches(1)
        let id = mailbox.post("never delivered").id
        #expect(mailbox.cancel(id) == .withdrawn)

        pump.release()
        _ = try await blocking.value
        await pump.stop()

        #expect(pump.batches.values.flatMap(\.self).allSatisfy { $0 != "never delivered" })
    }

    @Test("a mailbox that gets no message has an empty depth and no pending message")
    func mailboxWithNoMessageIsEmpty() {
        let mailbox = TestMailbox()

        #expect(mailbox.depth == MessageQueueDepth(waiting: 0, running: []))
        #expect(mailbox.depth.total == 0)
        #expect(mailbox.pending.isEmpty)
    }

    // MARK: - Races against a running batch

    @Test(
        "cancel of a message the pump already took reports cancelledInSubmission; a body that ignores the cancel still runs to its end"
    )
    func cancelOfATakenMessageReportsCancelledInSubmission() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let (id, answer) = mailbox.post("racing prompt")
        try await pump.waitForBatches(1)

        #expect(mailbox.cancel(id) == .cancelledInSubmission)
        await #expect(throws: CancellationError.self) { try await answer.value }

        pump.release()
        try await pump.waitForFinished(1)
        await pump.stop()
        #expect(pump.finished.values == [["racing prompt"]])
    }

    @Test("replace racing a running batch reports alreadySent; the batch delivers the original content")
    func replaceRacingARunningBatchReportsAlreadySent() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let (id, answer) = mailbox.post("original")
        try await pump.waitForBatches(1)

        #expect(mailbox.replace(id, with: "too late") == .alreadySent)

        pump.release()
        #expect(try await answer.value == TestPump.answer(to: ["original"]))
        await pump.stop()
        #expect(pump.batches.values == [["original"]])
    }

    @Test("a message posted while a batch runs is not swept into it, and goes into the next batch")
    func postDuringABatchGoesIntoTheNextBatch() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        mailbox.post("first")
        try await pump.waitForBatches(1)

        let secondId = mailbox.post("second").id
        #expect(mailbox.pending.map(\.id) == [secondId])

        pump.release()
        try await pump.waitForBatches(2)
        pump.release()
        try await pump.waitForFinished(2)
        await pump.stop()
        #expect(pump.batches.values == [["first"], ["second"]])
    }

    // MARK: - Depth

    @Test("the depth counts the waiting messages and names the messages of the running batch")
    func depthCountsWaitingAndRunningMessages() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let firstId = mailbox.post("first").id
        try await pump.waitForBatches(1)
        let (secondId, secondAnswer) = mailbox.post("second")

        // The first message runs; the second waits. The mailbox owes both an
        // answer.
        let midFlight = mailbox.depth
        #expect(midFlight.waiting == 1)
        #expect(midFlight.running == [firstId])
        #expect(midFlight.total == Self.postedMessageCount)

        pump.release()
        try await pump.waitForBatches(2)
        #expect(mailbox.depth == MessageQueueDepth(waiting: 0, running: [secondId]))

        pump.release()
        _ = try await secondAnswer.value
        #expect(mailbox.depth == MessageQueueDepth(waiting: 0, running: []))
        #expect(mailbox.depth.total == 0)
        await pump.stop()
    }

    /// How many messages ``depthCountsWaitingAndRunningMessages()`` posts.
    private static let postedMessageCount = 2

    // MARK: - cancel at every point of a message

    @Test("cancel withdraws a message that waits behind a running batch")
    func cancelWithdrawsAWaitingMessage() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        mailbox.post("blocking")
        try await pump.waitForBatches(1)
        let id = mailbox.post("withdraw me").id

        #expect(mailbox.cancel(id) == .withdrawn)
        #expect(mailbox.pending.isEmpty)

        pump.release()
        try await pump.waitForFinished(1)
        await pump.stop()
        #expect(pump.batches.values == [["blocking"]])
    }

    @Test("a postAndWait whose message waits is withdrawn by cancel: its caller gets CancellationError, and no batch carries it")
    func cancelWithdrawsAWaitingPostAndWait() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let blockingAnswer = Task { try await mailbox.postAndWait("blocking message") }
        try await pump.waitForBatches(1)

        // The caller of postAndWait never sees the id, so the test reads it
        // from the mailbox.
        let waiting = Task { try await mailbox.postAndWait("waiting prompt") }
        try #require(await BoundedWait.conditionReached("the message waits") { mailbox.depth.waiting == 1 })
        let id = try #require(mailbox.pending.first?.id)

        #expect(mailbox.cancel(id) == .withdrawn)

        pump.release()
        _ = try await blockingAnswer.value
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await pump.stop()
        #expect(pump.batches.values == [["blocking message"]])
    }

    @Test("cancel of a postAndWait message in a running batch reports cancelledInSubmission")
    func cancelOfARunningPostAndWait() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let answer = Task { try await mailbox.postAndWait("racing prompt") }
        try await pump.waitForBatches(1)
        let id = try #require(mailbox.depth.running.first)

        #expect(mailbox.cancel(id) == .cancelledInSubmission)
        await #expect(throws: CancellationError.self) { try await answer.value }

        pump.release()
        await pump.stop()
    }

    @Test("cancel reports alreadyAnswered for an answered message, and for an id that names no message")
    func cancelReportsAlreadyAnsweredForAFinishedMessage() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox, holding: false)

        let (id, answer) = mailbox.post("one and done")
        _ = try await answer.value
        await pump.stop()

        #expect(mailbox.cancel(id) == .alreadyAnswered)
        #expect(mailbox.cancel(MessageID()) == .alreadyAnswered)
    }

    // MARK: - No message is lost

    @Test("each posted message gets exactly one answer or a cancel result")
    func eachMessageGetsExactlyOneResult() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let (takenId, taken) = mailbox.post("taken")
        try await pump.waitForBatches(1)
        let (waitingId, waiting) = mailbox.post("waiting")
        let (_, answered) = mailbox.post("answered")
        #expect(mailbox.cancel(takenId) == .cancelledInSubmission)
        #expect(mailbox.cancel(waitingId) == .withdrawn)

        pump.release()
        try await pump.waitForBatches(2)
        pump.release()
        #expect(try await answered.value == TestPump.answer(to: ["answered"]))
        await pump.stop()

        // The body of the first batch ended after the cancel, and its answer
        // did not replace the cancel result.
        #expect(pump.finished.values == [["taken"], ["answered"]])
        await #expect(throws: CancellationError.self) { try await taken.value }
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(mailbox.depth == MessageQueueDepth(waiting: 0, running: []))
    }

    @Test("a poster cancelled while its message waits gets CancellationError, and its message leaves the mailbox")
    func cancelledPosterWithdrawsItsMessage() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        mailbox.post("blocking")
        try await pump.waitForBatches(1)
        let poster = Task { try await mailbox.postAndWait("cancelled poster") }
        try #require(await BoundedWait.conditionReached("the message waits") { mailbox.depth.waiting == 1 })

        poster.cancel()
        await #expect(throws: CancellationError.self) { try await poster.value }
        #expect(mailbox.pending.isEmpty)

        pump.release()
        try await pump.waitForFinished(1)
        await pump.stop()
        #expect(pump.batches.values == [["blocking"]])
    }

    @Test("a poster cancelled at once gets CancellationError, and leaves nothing in the mailbox")
    func posterCancelledAtOnceLeavesNothing() async {
        let mailbox = TestMailbox()

        let poster = Task { try await mailbox.postAndWait("cancelled at once") }
        poster.cancel()

        await #expect(throws: CancellationError.self) { try await poster.value }
        #expect(mailbox.depth == MessageQueueDepth(waiting: 0, running: []))
    }

    @Test("a poster cancelled while its batch runs gets CancellationError at once")
    func posterCancelledWhileItsBatchRuns() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let poster = Task { try await mailbox.postAndWait("running") }
        try await pump.waitForBatches(1)

        poster.cancel()
        await #expect(throws: CancellationError.self) { try await poster.value }

        pump.release()
        try await pump.waitForFinished(1)
        await pump.stop()
    }

    @Test("a pump cancelled while it waits takes nothing, and the next pump takes the messages posted after it")
    func pumpCancelledWhileItWaitsTakesNothing() async throws {
        let mailbox = TestMailbox()
        let cancelledPump = Task { await mailbox.answerNextBatch { _ in "never" } }

        cancelledPump.cancel()
        #expect(await cancelledPump.value == false)
        let (_, answer) = mailbox.post("kept")
        let pump = TestPump(mailbox, holding: false)

        #expect(try await answer.value == TestPump.answer(to: ["kept"]))
        await pump.stop()
    }

    @Test("a pump cancelled while its body runs gives the error of the body to each message of the batch")
    func pumpCancelledWhileItsBodyRuns() async throws {
        let mailbox = TestMailbox()
        let (_, first) = mailbox.post("first")
        let (_, second) = mailbox.post("second")

        // Both messages wait before the pump starts, so one batch takes both.
        let pump = TestPump(mailbox)
        try await pump.waitForBatches(1)
        await pump.stop()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(mailbox.depth == MessageQueueDepth(waiting: 0, running: []))
    }

    @Test("after a message of a taken batch is cancelled, the next batch gets every message posted after it")
    func nextBatchAfterACancelInATakenBatch() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let (takenId, taken) = mailbox.post("taken")
        try await pump.waitForBatches(1)
        #expect(mailbox.cancel(takenId) == .cancelledInSubmission)
        await #expect(throws: CancellationError.self) { try await taken.value }
        let (_, second) = mailbox.post("second")
        let (_, third) = mailbox.post("third")

        pump.release()
        try await pump.waitForBatches(2)
        pump.release()
        let expected = TestPump.answer(to: ["second", "third"])
        #expect(try await second.value == expected)
        #expect(try await third.value == expected)
        await pump.stop()
        #expect(pump.batches.values == [["taken"], ["second", "third"]])
    }

    @Test("a message that the joining rule refuses waits for a later batch, in order")
    func joiningRuleKeepsARefusedMessageForALaterBatch() async throws {
        let mailbox = TestMailbox()
        let answers = ["a1", "b1", "a2", "b2"].map { mailbox.post($0).answer }

        let pump = TestPump(mailbox, holding: false) { first, other in first.first == other.first }
        for answer in answers {
            _ = try await answer.value
        }
        await pump.stop()

        #expect(pump.batches.values == [["a1", "a2"], ["b1", "b2"]])
    }

    @Test("a released mailbox gives CancellationError to each message that waits")
    func releasedMailboxCancelsTheWaitingMessages() async throws {
        var mailbox: TestMailbox? = TestMailbox()
        let answer = try #require(mailbox).post("orphan").answer

        mailbox = nil

        await #expect(throws: CancellationError.self) { try await answer.value }
    }

    // MARK: - Messages that join the running batch

    @Test("a message posted while a batch runs, and taken with takeJoining, gets the answer of that batch")
    func joinedMessageGetsTheAnswerOfTheBatch() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        let (firstId, first) = mailbox.post("first")
        try await pump.waitForBatches(1)
        let (joinedId, joined) = mailbox.post("joined")

        try #require(mailbox.takeJoining { _ in true }.map(\.id) == [joinedId])
        #expect(mailbox.depth == MessageQueueDepth(waiting: 0, running: [firstId, joinedId]))

        pump.release()
        let expected = TestPump.answer(to: ["first"])
        #expect(try await first.value == expected)
        #expect(try await joined.value == expected)
        await pump.stop()
        #expect(pump.batches.values == [["first"]])
    }

    @Test("a message that the admitting rule refuses stays waiting, in order, and goes into the next batch")
    func refusedMessageStaysWaitingInOrder() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        mailbox.post("first")
        try await pump.waitForBatches(1)
        for message in ["a", "b", "c", "d"] {
            mailbox.post(message)
        }

        let taken = mailbox.takeJoining { $0 == "a" || $0 == "c" }
        #expect(taken.map(\.message) == ["a", "c"])
        #expect(mailbox.pending.map(\.message) == ["b", "d"])

        pump.release()
        try await pump.waitForBatches(2)
        pump.release()
        try await pump.waitForFinished(2)
        await pump.stop()
        #expect(pump.batches.values == [["first"], ["b", "d"]])
    }

    @Test("a message cancelled before takeJoining gets CancellationError, and the take does not return it")
    func messageCancelledBeforeTheTakeIsNotReturned() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        mailbox.post("first")
        try await pump.waitForBatches(1)
        let (id, cancelled) = mailbox.post("cancelled")
        #expect(mailbox.cancel(id) == .withdrawn)

        #expect(mailbox.takeJoining { _ in true }.isEmpty)
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        pump.release()
        try await pump.waitForFinished(1)
        await pump.stop()
    }

    @Test("cancel of a joined message reports cancelledInSubmission")
    func cancelOfAJoinedMessageReportsCancelledInSubmission() async throws {
        let mailbox = TestMailbox()
        let pump = TestPump(mailbox)

        mailbox.post("first")
        try await pump.waitForBatches(1)
        let (id, joined) = mailbox.post("joined")
        try #require(mailbox.takeJoining { _ in true }.map(\.id) == [id])

        #expect(mailbox.cancel(id) == .cancelledInSubmission)
        await #expect(throws: CancellationError.self) { try await joined.value }

        pump.release()
        try await pump.waitForFinished(1)
        await pump.stop()
    }

    @Test("with no running batch, takeJoining returns no message and the messages keep waiting")
    func takeJoiningWithNoRunningBatchReturnsNothing() async {
        let mailbox = TestMailbox()

        mailbox.post("before any batch")
        #expect(mailbox.takeJoining { _ in true }.isEmpty)

        // One batch runs to its end; after it, no batch runs.
        await mailbox.answerNextBatch { _ in "done" }
        mailbox.post("after the batch")
        #expect(mailbox.takeJoining { _ in true }.isEmpty)
        #expect(mailbox.pending.map(\.message) == ["after the batch"])
    }

    @Test("a batch that throws gives its error to the joined messages too")
    func failedBatchGivesItsErrorToTheJoinedMessages() async throws {
        let mailbox = TestMailbox()
        let (mayEnd, end) = AsyncStream.makeStream(of: Void.self)
        let (_, first) = mailbox.post("first")
        let pump = Task {
            await mailbox.answerNextBatch { _ in
                for await _ in mayEnd {}
                throw BatchFailure()
            }
        }
        try #require(await BoundedWait.conditionReached("the batch runs") { mailbox.depth.running.count == 1 })
        let (joinedId, joined) = mailbox.post("joined")
        try #require(mailbox.takeJoining { _ in true }.map(\.id) == [joinedId])

        end.finish()
        #expect(await pump.value)
        await #expect(throws: BatchFailure.self) { try await first.value }
        await #expect(throws: BatchFailure.self) { try await joined.value }
    }

    /// The error of the batch in ``failedBatchGivesItsErrorToTheJoinedMessages()``.
    private struct BatchFailure: Error {}

    // MARK: - README

    @Test("the README example: post, wait, and cancel through a mailbox")
    func readmeMailboxExample() async throws {
        // README example: begin
        let mailbox = Mailbox<String, String>()

        // The one pump takes each batch. Each message of the batch gets the
        // answer of the batch.
        let pump = Task {
            while await mailbox.answerNextBatch({ letters in
                "read " + letters.map(\.message).joined(separator: " and ")
            }) {}
        }

        // Post a message, and read its answer later.
        let (id, answer) = mailbox.post("hello")

        // Or post, and wait for the answer in one call. A cancel of the
        // caller cancels the message.
        let reply = try await mailbox.postAndWait("how are you?")

        // A message that waits can change (`replace`) or leave (`cancel`).
        // The result tells what occurred: here the message has its answer.
        let result = mailbox.cancel(id)
        let greeting = try await answer.value
        pump.cancel()
        // README example: end

        #expect(result == .alreadyAnswered)
        #expect(greeting.contains("hello"))
        #expect(reply.contains("how are you?"))
    }
}
