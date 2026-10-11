/// A first-in, first-out chain of asynchronous deliveries.
///
/// ``enqueue(body:)`` does not suspend, so an actor that keeps the chain in
/// its own state fixes the place of each delivery when it calls the method.
/// A delivery starts only after each earlier delivery ends.
///
/// A chain made with a queue recorder records each delivery as one task of
/// the queue metrics. The depth goes up at ``enqueue(body:)`` and goes down
/// when the delivery ends. When the delivery ends, the chain records one wait
/// time (from the enqueue to the start), one run time (from the start to the
/// end) and one count. The body cannot throw, thus the outcome of each
/// delivery is `succeeded`. The metrics never hold the content of a delivery.
/// A chain made with ``init()`` records no metric.
public struct SerialAsyncChain: Sendable {
    /// The queue metrics of one delivery: the recorder of the chain, and the
    /// ticket of the delivery.
    private struct DeliveryRecord: Sendable {
        /// The recorder of the chain.
        let telemetry: QueueTelemetry

        /// The ticket of the delivery, from the enqueue.
        var ticket: QueueTicket

        /// Records that the delivery starts now.
        mutating func start() {
            telemetry.started(&ticket)
        }

        /// Records that the delivery ended with success.
        func complete() {
            telemetry.completed(ticket, outcome: .succeeded)
        }
    }

    /// The last delivery that was enqueued, or `nil` before the first one.
    private var tail: Task<Void, Never>?

    /// The recorder of the queue metrics of the deliveries, or `nil` for a
    /// chain that records no metric.
    private let telemetry: QueueTelemetry?

    /// Makes an empty chain that records no metric.
    public init() {
        self.init(telemetry: nil)
    }

    /// Makes an empty chain that records the queue metrics of each delivery
    /// with `telemetry`.
    ///
    /// - Parameter telemetry: The recorder of the queue metrics, or `nil` for
    ///   a chain that records no metric.
    init(telemetry: QueueTelemetry?) {
        self.telemetry = telemetry
    }

    /// Adds `body` behind each delivery that is already in the chain.
    ///
    /// - Parameter body: The delivery. It starts after each earlier one ends.
    /// - Returns: The task of the delivery, for a caller that waits for it.
    public mutating func enqueue(body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        // The ticket is made now, on the task of the caller, so that it keeps
        // the metrics factory of the caller.
        let enqueued = telemetry.map { DeliveryRecord(telemetry: $0, ticket: $0.enqueued()) }
        let delivery = Task {
            var record = enqueued
            await previous?.value
            record?.start()
            await body()
            record?.complete()
        }
        tail = delivery
        return delivery
    }
}
