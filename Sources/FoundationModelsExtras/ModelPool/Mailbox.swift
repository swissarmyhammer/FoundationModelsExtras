import Synchronization

/// A first-in, first-out queue of messages to one consumer, with one answer
/// for each message.
///
/// A poster calls ``post(_:)``, which returns at once, or ``postAndWait(_:)``.
/// The one consumer (the pump) calls ``answerNextBatch(isolation:joining:_:)``
/// in a loop. Each message gets exactly one result: the answer of its batch,
/// the error of its batch, or `CancellationError`. A message is never lost,
/// also when the poster or the pump is cancelled.
///
/// Post, cancel, replace, the take of a batch and ``takeJoining(admitting:)``
/// each occur under one lock and do not suspend. Thus a cancel is never late
/// for the take: the message is in the queue or in the running batch, and the
/// cancel finds it.
///
/// Each message is one task of the queue metrics, with the queue name
/// `mailbox` and, when ``init(model:)`` got a model, the model ref. The depth
/// goes up at ``post(_:)``, and goes down when the message gets its result.
/// When the message gets its result, the mailbox records one wait time, one
/// run time when a batch took the message, and one count with the outcome.
/// The metrics never hold a message or an answer.
public final class Mailbox<Message: Sendable, Answer: Sendable>: Sendable {
    /// One posted message and its answer.
    public struct Letter: Sendable {
        /// The id that ``Mailbox/post(_:)`` returned.
        public let id: MessageID

        /// The message. ``Mailbox/replace(_:with:)`` changes it while it waits.
        public internal(set) var message: Message

        /// The result that the poster waits for.
        let result = Promise<Result<Answer, any Error>>()
    }

    /// One letter of the mailbox, and its queue ticket.
    private struct Entry: Sendable {
        /// The letter.
        var letter: Letter

        /// The queue ticket of the letter, from ``Mailbox/post(_:)``. The
        /// take of the letter into a batch sets its start instant.
        var ticket: QueueTicket
    }

    /// The letters of the mailbox, and the doorbell of the pump.
    private struct State {
        /// The letters that wait for the pump, in the order they arrived.
        var waiting: [Entry] = []

        /// The letters of the batch that runs.
        var running: [Entry] = []

        /// Whether ``Mailbox/answerNextBatch(isolation:joining:_:)`` runs a
        /// batch. Not `running.isEmpty`: a cancel can empty `running` while
        /// the batch still runs.
        var isBatchRunning = false

        /// Rung by ``post(_:)`` when the pump waits for a letter.
        var doorbell: AsyncStream<Void>.Continuation?
    }

    /// The state of the mailbox.
    private let state = Mutex(State())

    /// The recorder of the queue metrics of the letters.
    private let telemetry: QueueTelemetry

    /// Makes an empty mailbox. `Mailbox()` makes a mailbox with no model.
    ///
    /// - Parameter model: The model that the mailbox belongs to, or `nil`.
    ///   It gives the model ref dimension of each queue metric. The queue
    ///   name is always `mailbox`.
    public init(model: ModelRef? = nil) {
        telemetry = QueueTelemetry(name: .mailbox, model: model)
    }

    /// Gives `CancellationError` to each letter that still waits.
    deinit {
        for entry in state.withLock({ $0.waiting }) {
            finish(entry, with: .failure(CancellationError()))
        }
    }

    /// Adds `message` behind every message that waits. Does not wait.
    ///
    /// - Parameter message: The message.
    /// - Returns: The id of the message, and its answer.
    @discardableResult
    public func post(_ message: Message) -> (id: MessageID, answer: MailboxAnswer<Answer>) {
        let letter = Letter(id: MessageID(), message: message)
        let entry = Entry(letter: letter, ticket: telemetry.enqueued())
        let doorbell = state.withLock { state in
            state.waiting.append(entry)
            defer { state.doorbell = nil }
            return state.doorbell
        }
        doorbell?.finish()
        return (letter.id, MailboxAnswer(result: letter.result))
    }

    /// Posts `message`, and waits for its answer. A cancel of the caller
    /// cancels the message (``cancel(_:)``).
    ///
    /// - Parameter message: The message.
    /// - Returns: The answer of the batch that carried the message.
    /// - Throws: The error of that batch, or `CancellationError`.
    public func postAndWait(_ message: Message) async throws -> Answer {
        let (id, answer) = post(message)
        return try await withTaskCancellationHandler {
            try await answer.value
        } onCancel: {
            cancel(id)
        }
    }

    /// Cancels the message `id`.
    ///
    /// - Parameter id: The id of the message.
    /// - Returns: What occurred to the message.
    @discardableResult
    public func cancel(_ id: MessageID) -> MessageCancellationResult {
        let (entry, outcome) = state.withLock { state -> (Entry?, MessageCancellationResult) in
            if let index = state.waiting.firstIndex(where: { $0.letter.id == id }) {
                return (state.waiting.remove(at: index), .withdrawn)
            }
            if let index = state.running.firstIndex(where: { $0.letter.id == id }) {
                return (state.running.remove(at: index), .cancelledInSubmission)
            }
            return (nil, .alreadyAnswered)
        }
        if let entry {
            finish(entry, with: .failure(CancellationError()))
        }
        return outcome
    }

    /// Replaces the message `id` while it waits. It keeps its place.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - message: The new message.
    /// - Returns: Whether the message waited and changed.
    @discardableResult
    public func replace(_ id: MessageID, with message: Message) -> MessageQueueMutationResult {
        state.withLock { state in
            guard let index = state.waiting.firstIndex(where: { $0.letter.id == id }) else { return .alreadySent }
            state.waiting[index].letter.message = message
            return .applied
        }
    }

    /// The letters that wait for the pump, in the order they arrived.
    public var pending: [Letter] {
        state.withLock { $0.waiting.map(\.letter) }
    }

    /// The count of the waiting messages, and the ids of the running batch.
    public var depth: MessageQueueDepth {
        state.withLock { MessageQueueDepth(waiting: $0.waiting.count, running: $0.running.map(\.letter.id)) }
    }

    /// Takes each waiting message that `admitting` accepts into the batch that
    /// runs now. Does not wait. Only the body of that batch calls this.
    ///
    /// The taken messages get the result of the batch. The other messages
    /// keep their order. With no running batch, nothing is taken.
    ///
    /// - Parameter admitting: Whether a waiting message joins the batch.
    /// - Returns: The taken letters, in the order they arrived.
    public func takeJoining(admitting: (Message) -> Bool) -> [Letter] {
        state.withLock { state in
            guard state.isBatchRunning else { return [] }
            // `admitting` runs one time for each letter, so it can keep a budget.
            let checked = state.waiting.map { (entry: $0, joins: admitting($0.letter.message)) }
            let joining = checked.filter(\.joins).map { started($0.entry) }
            state.waiting = checked.filter { !$0.joins }.map(\.entry)
            state.running += joining
            return joining.map(\.letter)
        }
    }

    /// Waits for the next batch, takes it, and gives the result of `body` to
    /// each message of the batch. Only one pump calls this at a time.
    ///
    /// The first waiting message starts the batch. Each later waiting message
    /// that `joins` accepts comes with it; the others keep their order.
    ///
    /// - Parameters:
    ///   - isolation: The actor isolation of the caller.
    ///   - joins: Whether a message (the second argument) can share the batch
    ///     of the first message (the first argument).
    ///   - body: Makes the answer of the batch.
    /// - Returns: `false` when the pump was cancelled before a batch came.
    ///   Then nothing was taken.
    @discardableResult
    public func answerNextBatch(
        isolation: isolated (any Actor)? = #isolation,
        joining joins: (Message, Message) -> Bool = { _, _ in true },
        _ body: ([Letter]) async throws -> Answer
    ) async -> Bool {
        guard let batch = await nextBatch(isolation: isolation, joining: joins) else { return false }
        let result: Result<Answer, any Error>
        do {
            result = .success(try await body(batch))
        } catch {
            result = .failure(error)
        }
        let answered = state.withLock { state in
            defer {
                state.running = []
                state.isBatchRunning = false
            }
            return state.running
        }
        for entry in answered {
            finish(entry, with: result)
        }
        return true
    }

    /// Gives `entry` with the start instant set in its ticket. A batch takes
    /// the entry now. The ticket records no metric here, thus the call is
    /// correct under the lock.
    ///
    /// - Parameter entry: The entry that a batch takes.
    /// - Returns: The entry, with the start instant in its ticket.
    private func started(_ entry: Entry) -> Entry {
        var taken = entry
        telemetry.started(&taken.ticket)
        return taken
    }

    /// Records the completion of `entry`, then gives `result` to its poster.
    /// Call this after the lock is released, one time for each entry that
    /// leaves the mailbox.
    ///
    /// - Parameters:
    ///   - entry: The entry that left the mailbox.
    ///   - result: The result of the letter. It also gives the outcome of
    ///     the queue metrics.
    private func finish(_ entry: Entry, with result: Result<Answer, any Error>) {
        telemetry.completed(entry.ticket, outcome: QueueOutcome(of: result))
        entry.letter.result.fulfill(result)
    }

    /// Waits until a letter waits, and takes the batch that it starts.
    ///
    /// - Parameters:
    ///   - isolation: The actor isolation of the caller.
    ///   - joins: The joining rule of the batch.
    /// - Returns: The batch, or `nil` when the task was cancelled.
    private func nextBatch(
        isolation: isolated (any Actor)?, joining joins: (Message, Message) -> Bool
    ) async -> [Letter]? {
        while !Task.isCancelled {
            let (rung, doorbell) = AsyncStream.makeStream(of: Void.self)
            let batch = state.withLock { state -> [Letter]? in
                guard let first = state.waiting.first else {
                    state.doorbell = doorbell
                    return nil
                }
                let later = state.waiting.dropFirst()
                let taken = [first] + later.filter { joins(first.letter.message, $0.letter.message) }
                state.running = taken.map { started($0) }
                state.waiting = later.filter { !joins(first.letter.message, $0.letter.message) }
                state.isBatchRunning = true
                return state.running.map(\.letter)
            }
            if let batch { return batch }
            for await _ in rung {}
        }
        return nil
    }
}

/// The answer of one message of a ``Mailbox``.
public struct MailboxAnswer<Value: Sendable>: Sendable {
    /// The result that the mailbox gives.
    let result: Promise<Result<Value, any Error>>

    /// The answer. Waits until the message has its result.
    ///
    /// - Throws: The error of the batch, or `CancellationError` when the
    ///   message was cancelled.
    public var value: Value {
        get async throws { try await result.value.get() }
    }
}
