import Synchronization

/// A first-in, first-out queue of ``Mail`` for one session, with no answers.
///
/// The queue only holds mail. It keeps no rules for the kinds of mail: the
/// session gives the batch rule to ``take(admitting:)``, and the session owns
/// the coalescing of progress, the held mail and the terminal events. The
/// queue gives no answer and keeps no promise for a mail.
///
/// Each operation occurs under one lock and does not suspend. Only
/// ``waitForMail()`` suspends. Thus a cancel is never late for a take: the
/// mail is in the queue, or a take has removed it.
///
/// A pause stops ``take(admitting:)``, for example while a compaction runs.
/// ``pause()`` and ``resume()`` are a counter, because one compaction can
/// follow an other: the queue stays paused until each pause has its resume.
/// Put, cancel and replace work while the queue is paused.
///
/// Each mail is one task of the queue metrics, with the queue name
/// `mail_queue` and, when ``init(model:)`` got a model, the model ref. The
/// depth goes up at ``put(_:)`` and ``putBack(_:)``, and goes down when the
/// mail leaves the queue. A take records one wait time and the outcome
/// `succeeded`, with no run time. A cancel, a drain and a close record the
/// outcome `cancelled`. The metrics never hold the content of a mail.
public final class MailQueue: Sendable {
    /// One queued mail, and its queue ticket.
    private struct Entry: Sendable {
        /// The mail.
        var mail: Mail

        /// The queue ticket of the mail, from the put or the put back.
        let ticket: QueueTicket
    }

    /// The mail of the queue, the pause counter and the waiters.
    private struct State {
        /// The queued mail, in queue order.
        var queued: [Entry] = []

        /// The number of pauses that have no resume yet. The queue is paused
        /// while this is above 0.
        var pauseCount = 0

        /// Whether ``MailQueue/close()`` ran.
        var isClosed = false

        /// The doorbells of the callers of ``MailQueue/waitForMail()``, by
        /// their key.
        var doorbells: [Int: AsyncStream<Void>.Continuation] = [:]

        /// The key of the next doorbell.
        var nextDoorbellKey = 0

        /// Whether a waiter can stop its wait: the queue is closed, or the
        /// queue is not paused and holds mail.
        var isReady: Bool {
            isClosed || (pauseCount == 0 && !queued.isEmpty)
        }

        /// Removes and gives each doorbell when the queue is ready. Ring the
        /// doorbells after the lock is released.
        ///
        /// - Returns: The doorbells to ring, or none when the queue is not
        ///   ready.
        mutating func doorbellsToRing() -> [AsyncStream<Void>.Continuation] {
            guard isReady else { return [] }
            defer { doorbells = [:] }
            return Array(doorbells.values)
        }
    }

    /// The state of the queue.
    private let state = Mutex(State())

    /// The recorder of the queue metrics of the mail.
    private let telemetry: QueueTelemetry

    /// Makes an empty queue. `MailQueue()` makes a queue with no model.
    ///
    /// - Parameter model: The model that the queue belongs to, or `nil`. It
    ///   gives the model ref dimension of each queue metric. The queue name
    ///   is always `mail_queue`.
    public init(model: ModelRef? = nil) {
        telemetry = QueueTelemetry(name: .mailQueue, model: model)
    }

    /// Adds `mail` at the end of the queue. Does not wait.
    ///
    /// The queue checks for a duplicate id only in its own queue. The session
    /// also checks the mail of its open answer.
    ///
    /// - Parameter mail: The mail.
    /// - Throws: ``MailRefusal/duplicateID(_:)`` when a mail with the same id
    ///   is in the queue, or ``MailRefusal/closed`` after ``close()``.
    public func put(_ mail: Mail) throws {
        let doorbells = try state.withLock { state in
            guard !state.isClosed else { throw MailRefusal.closed }
            guard !state.queued.contains(where: { $0.mail.id == mail.id }) else {
                throw MailRefusal.duplicateID(mail.id)
            }
            // The ticket is made under the lock, so that a refused mail
            // records no metric and the depth changes in queue order.
            state.queued.append(Entry(mail: mail, ticket: telemetry.enqueued()))
            return state.doorbellsToRing()
        }
        ring(doorbells)
    }

    /// Takes each queued mail that `rule` accepts, in queue order. Does not
    /// wait.
    ///
    /// The queue goes through the mail in FIFO order. For each mail, it calls
    /// `rule` with that mail and the batch that it took before. It takes the
    /// mail when `rule` gives `true`. The mail that it does not take stays in
    /// the queue, in its order. The session uses this one function both for a
    /// new batch and for a join into the answer that runs, with a different
    /// rule each time.
    ///
    /// `rule` runs under the lock of the queue. It must not call the queue.
    ///
    /// - Parameter rule: Whether `candidate` joins `batch`, the mail taken
    ///   before it.
    /// - Returns: The taken mail, in queue order. It is empty while the queue
    ///   is paused.
    public func take(admitting rule: (_ candidate: Mail, _ batch: [Mail]) -> Bool) -> [Mail] {
        state.withLock { state in
            guard state.pauseCount == 0 else { return [] }
            var batch: [Mail] = []
            var left: [Entry] = []
            for entry in state.queued {
                if rule(entry.mail, batch) {
                    batch.append(entry.mail)
                    telemetry.completed(entry.ticket, outcome: .succeeded)
                } else {
                    left.append(entry)
                }
            }
            state.queued = left
            return batch
        }
    }

    /// Puts mail back at the front of the queue, in the given order. Does
    /// not check for a duplicate id.
    ///
    /// The session calls this for a requeue after a failed submission, and
    /// for mail that it took but did not use. Each mail starts a new task of
    /// the queue metrics.
    ///
    /// After ``close()``, the queue refuses all the mail and records no
    /// metric. A closed queue is never drained again, thus refused mail
    /// would get no terminal event in the queue. The session sends the
    /// terminal event of each refused mail.
    ///
    /// - Parameter mails: The mail, in the order that it gets at the front.
    /// - Returns: The refused mail, in the given order. It is empty when the
    ///   queue is open.
    @discardableResult
    public func putBack(_ mails: [Mail]) -> [Mail] {
        guard !mails.isEmpty else { return [] }
        let (refused, doorbells) = state.withLock { state -> ([Mail], [AsyncStream<Void>.Continuation]) in
            guard !state.isClosed else { return (mails, []) }
            state.queued.insert(contentsOf: mails.map { Entry(mail: $0, ticket: telemetry.enqueued()) }, at: 0)
            return ([], state.doorbellsToRing())
        }
        ring(doorbells)
        return refused
    }

    /// Removes one queued mail. Does not touch mail that a take removed.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The removed mail, or `nil` when the mail is not in the
    ///   queue.
    @discardableResult
    public func cancel(_ id: MailID) -> Mail? {
        state.withLock { state in
            guard let index = state.queued.firstIndex(where: { $0.mail.id == id }) else { return nil }
            let entry = state.queued.remove(at: index)
            telemetry.completed(entry.ticket, outcome: .cancelled)
            return entry.mail
        }
    }

    /// Changes the body of one queued mail. The id, the sender and the place
    /// in the queue do not change.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - body: The new body.
    /// - Returns: `false` when the mail is not in the queue.
    @discardableResult
    public func replace(_ id: MailID, with body: MailBody) -> Bool {
        state.withLock { state in
            guard let index = state.queued.firstIndex(where: { $0.mail.id == id }) else { return false }
            let old = state.queued[index].mail
            state.queued[index].mail = Mail(id: old.id, sender: old.sender, body: body)
            return true
        }
    }

    /// Adds one pause. While the queue has a pause, ``take(admitting:)``
    /// gives no mail.
    public func pause() {
        state.withLock { $0.pauseCount += 1 }
    }

    /// Removes one pause. With no pause, it does nothing. When the last
    /// pause goes, the waiters of ``waitForMail()`` stop their wait if the
    /// queue holds mail.
    public func resume() {
        let doorbells = state.withLock { state in
            guard state.pauseCount > 0 else { return [AsyncStream<Void>.Continuation]() }
            state.pauseCount -= 1
            return state.doorbellsToRing()
        }
        ring(doorbells)
    }

    /// Removes all queued mail. The queue stays open.
    ///
    /// - Returns: The removed mail, in queue order.
    @discardableResult
    public func drain() -> [Mail] {
        state.withLock { removeAll(from: &$0) }
    }

    /// Removes all queued mail, and closes the queue: after this, ``put(_:)``
    /// throws ``MailRefusal/closed``, ``putBack(_:)`` refuses all the mail,
    /// and ``waitForMail()`` returns `false` at once.
    ///
    /// - Returns: The removed mail, in queue order.
    @discardableResult
    public func close() -> [Mail] {
        let (removed, doorbells) = state.withLock { state in
            let removed = removeAll(from: &state)
            state.isClosed = true
            return (removed, state.doorbellsToRing())
        }
        ring(doorbells)
        return removed
    }

    /// The queued mail, in queue order.
    public var pending: [Mail] {
        state.withLock { $0.queued.map(\.mail) }
    }

    /// The number of queued mail of each kind. A kind with no queued mail
    /// has no key.
    public var depthByKind: [MailKind: Int] {
        state.withLock { state in
            state.queued.reduce(into: [:]) { counts, entry in counts[entry.mail.body.kind, default: 0] += 1 }
        }
    }

    /// The number of callers of ``waitForMail()`` that wait now.
    var waiterCount: Int {
        state.withLock { $0.doorbells.count }
    }

    /// Waits until the queue is not paused and holds mail, or until the queue
    /// is closed. Returns at once when this is already true, and returns when
    /// the task is cancelled.
    ///
    /// The session calls this to wake its pump. A ``take(admitting:)`` after
    /// the return can still give no mail: an other caller can take the mail
    /// first, the queue can pause again, or the rule can refuse all the mail.
    /// That is correct. The pump then waits again.
    ///
    /// - Returns: `false` when the queue is closed, thus the pump must stop.
    ///   `true` in all other cases: the queue is ready, or the task was
    ///   cancelled. The caller checks `Task.isCancelled`.
    @discardableResult
    public func waitForMail() async -> Bool {
        let (rung, doorbell) = AsyncStream.makeStream(of: Void.self)
        let key = state.withLock { state in
            defer { state.nextDoorbellKey += 1 }
            return state.nextDoorbellKey
        }
        // The handler is set before the doorbell goes into the state. Thus a
        // waiter that is cancelled at any time removes its own doorbell, and
        // the state does not keep doorbells that nobody waits on.
        doorbell.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.doorbells.removeValue(forKey: key) }
        }
        let isWaiting = state.withLock { state in
            guard !state.isReady else { return false }
            state.doorbells[key] = doorbell
            return true
        }
        if isWaiting {
            for await _ in rung {}
        }
        return !state.withLock { $0.isClosed }
    }

    /// Removes all queued mail, and records each mail as cancelled.
    ///
    /// - Parameter state: The state of the queue, under the lock.
    /// - Returns: The removed mail, in queue order.
    private func removeAll(from state: inout State) -> [Mail] {
        defer { state.queued = [] }
        for entry in state.queued {
            telemetry.completed(entry.ticket, outcome: .cancelled)
        }
        return state.queued.map(\.mail)
    }

    /// Rings each doorbell, so that each waiter of ``waitForMail()`` stops
    /// its wait. Call this after the lock is released.
    ///
    /// - Parameter doorbells: The doorbells to ring.
    private func ring(_ doorbells: [AsyncStream<Void>.Continuation]) {
        for doorbell in doorbells {
            doorbell.finish()
        }
    }
}
