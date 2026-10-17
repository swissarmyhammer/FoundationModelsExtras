import Metrics

/// The shared recorder of the metrics of one queue: the depth of the queue,
/// and the wait time, the run time and the count of each task when it
/// completes.
///
/// Each queue of the package uses this one recorder, thus each queue records
/// the same names with the same rules. The recorder records ids, names and
/// counts only. It never records the content of a task.
///
/// The queue calls ``enqueued()`` when it accepts a task, ``started(_:)``
/// when the task starts, and ``completed(_:outcome:)`` when the task ends. A
/// task that is cancelled before it starts gets no ``started(_:)`` call: its
/// completion records the wait time, no run time, and
/// ``QueueOutcome/cancelled``.
///
/// A queue that makes the ticket of a task before it accepts the task calls
/// ``makeTicket()`` first, and ``accepted(_:)`` in the step that accepts the
/// task. A task that ends before that step calls ``refused(_:)`` in place of
/// ``completed(_:outcome:)``. Thus the depth goes up only for a task that the
/// queue accepted, and down only for a task that went up.
///
/// - ``ExtrasTelemetry/MetricName/queueDepth`` goes up by one at
///   ``enqueued()`` or ``accepted(_:)``, and down by one at
///   ``completed(_:outcome:)``. Its dimensions are the queue name and, when
///   set, the model ref.
/// - ``ExtrasTelemetry/MetricName/queueWait``,
///   ``ExtrasTelemetry/MetricName/queueRun`` and
///   ``ExtrasTelemetry/MetricName/queueTasks`` are recorded together at
///   ``completed(_:outcome:)`` or ``refused(_:)``. Their dimensions are the
///   queue name, the model ref when set, and the outcome.
///
/// Each metric is made at call time with the factory that the
/// ``QueueTicket`` keeps from ``enqueued()``, not with the factory of the
/// current task. Thus a completion that runs in a `Task.detached` reaches the
/// factory of the submitter.
struct QueueTelemetry: Sendable {
    /// The queue that this recorder records.
    let name: QueueName

    /// The model that the queue belongs to, or `nil` when the queue does not
    /// belong to one model.
    let model: ModelRef?

    /// Gives the current instant: the enqueue, the start and the end of each
    /// task.
    private let now: @Sendable () -> ContinuousClock.Instant

    /// Makes the recorder of one queue.
    ///
    /// - Parameters:
    ///   - name: The queue that the recorder records.
    ///   - model: The model that the queue belongs to, or `nil` when the
    ///     queue does not belong to one model.
    ///   - now: Gives the current instant. The default reads
    ///     `ContinuousClock`. A test gives the instant of a manual clock, and
    ///     then each wait time and each run time is the move of that clock.
    init(
        name: QueueName, model: ModelRef? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.name = name
        self.model = model
        self.now = now
    }

    /// Records that the queue accepted one task: the depth goes up by one.
    ///
    /// - Returns: The ticket of the task. It keeps the enqueue instant and
    ///   the metrics factory that is bound now.
    func enqueued() -> QueueTicket {
        let ticket = makeTicket()
        accepted(ticket)
        return ticket
    }

    /// Makes the ticket of one task, and records nothing. Call
    /// ``accepted(_:)`` when the queue accepts the task.
    ///
    /// - Returns: The ticket of the task. It keeps the instant now and the
    ///   metrics factory that is bound now.
    func makeTicket() -> QueueTicket {
        QueueTicket(factory: MetricsSystem.factory, enqueuedAt: now())
    }

    /// Records that the queue accepted the task of `ticket`: the depth goes
    /// up by one.
    ///
    /// The metrics factory of the ticket records the change on the calling
    /// thread. A queue can thus call this function under its own lock, in
    /// the step that accepts the task.
    ///
    /// - Parameter ticket: The ticket that ``makeTicket()`` made.
    func accepted(_ ticket: QueueTicket) {
        depthMeter(factory: ticket.factory).increment()
    }

    /// Records that the task of `ticket` started.
    ///
    /// - Parameter ticket: The ticket of the task. It keeps the start
    ///   instant.
    func started(_ ticket: inout QueueTicket) {
        ticket.startedAt = now()
    }

    /// Records that the task of `ticket` ended: the depth goes down by one,
    /// and the wait time, the run time and one count are recorded with the
    /// outcome.
    ///
    /// The wait time is the time from the enqueue to the start. For a task
    /// that did not start, it is the time from the enqueue to this call, and
    /// no run time is recorded.
    ///
    /// - Parameters:
    ///   - ticket: The ticket of the task.
    ///   - outcome: How the task ended.
    func completed(_ ticket: QueueTicket, outcome: QueueOutcome) {
        depthMeter(factory: ticket.factory).decrement()
        recordEnd(of: ticket, outcome: outcome)
    }

    /// Records that the task of `ticket` was cancelled before the queue
    /// accepted it: the wait time and one count, with
    /// ``QueueOutcome/cancelled``. The depth does not change, because
    /// ``accepted(_:)`` never counted the task.
    ///
    /// - Parameter ticket: The ticket that ``makeTicket()`` made.
    func refused(_ ticket: QueueTicket) {
        recordEnd(of: ticket, outcome: .cancelled)
    }

    /// Records the wait time, the run time when the task started, and one
    /// count, with `outcome`.
    ///
    /// - Parameters:
    ///   - ticket: The ticket of the task.
    ///   - outcome: How the task ended.
    private func recordEnd(of ticket: QueueTicket, outcome: QueueOutcome) {
        let end = now()
        let factory = ticket.factory
        let dimensions = queueDimensions + [(ExtrasTelemetry.DimensionKey.queueOutcome, outcome.rawValue)]
        Metrics.Timer(label: ExtrasTelemetry.MetricName.queueWait, dimensions: dimensions, factory: factory)
            .record(duration: (ticket.startedAt ?? end) - ticket.enqueuedAt)
        if let startedAt = ticket.startedAt {
            Metrics.Timer(label: ExtrasTelemetry.MetricName.queueRun, dimensions: dimensions, factory: factory)
                .record(duration: end - startedAt)
        }
        Counter(label: ExtrasTelemetry.MetricName.queueTasks, dimensions: dimensions, factory: factory)
            .increment()
    }

    /// The depth meter of the queue, made with `factory`.
    ///
    /// - Parameter factory: The metrics factory of a ticket.
    /// - Returns: The meter.
    private func depthMeter(factory: any MetricsFactory) -> Meter {
        Meter(label: ExtrasTelemetry.MetricName.queueDepth, dimensions: queueDimensions, factory: factory)
    }

    /// The dimensions of the queue: the queue name, then the model ref when
    /// the queue belongs to one model.
    private var queueDimensions: [(String, String)] {
        let modelDimension = model.map { [(ExtrasTelemetry.DimensionKey.modelRef, $0.stringValue)] } ?? []
        return [(ExtrasTelemetry.DimensionKey.queueName, name.rawValue)] + modelDimension
    }
}

extension QueueOutcome {
    /// Gives the outcome of a queue task that ran to a result.
    ///
    /// - Parameter result: The result of the task.
    /// - Returns: ``succeeded`` for a value, ``cancelled`` for a
    ///   `CancellationError`, and ``failed`` for each other error.
    init(of result: Result<some Any, any Error>) {
        switch result {
        case .success:
            self = .succeeded
        case .failure(let error):
            self = error is CancellationError ? .cancelled : .failed
        }
    }
}

/// The record of one queue task between its enqueue and its completion.
///
/// The ticket keeps the metrics factory that was bound when
/// ``QueueTelemetry/enqueued()`` or ``QueueTelemetry/makeTicket()`` made it,
/// so that the acceptance, the start and the completion
/// record with the factory of the submitter, also from another task.
struct QueueTicket: Sendable {
    /// The metrics factory that was bound at the enqueue.
    let factory: any MetricsFactory

    /// The instant of the enqueue.
    let enqueuedAt: ContinuousClock.Instant

    /// The instant of the start, or `nil` while the task has not started.
    fileprivate(set) var startedAt: ContinuousClock.Instant?
}
