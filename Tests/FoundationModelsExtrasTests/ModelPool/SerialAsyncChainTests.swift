@testable import FoundationModelsExtras
import Metrics
import MetricsTestKit
import Testing

/// ``SerialAsyncChain`` runs its deliveries one at a time, in the order of
/// the enqueue.
@Suite("SerialAsyncChain: one delivery at a time, first in, first out")
struct SerialAsyncChainTests {
    /// The number of deliveries that each test enqueues.
    private static let deliveryCount = 5

    /// The number of times each delivery yields between its start and its end.
    private static let yieldsInsideADelivery = 10

    @Test("a delivery starts only after every earlier delivery ends")
    func deliveriesDoNotOverlap() async {
        let steps = Recorder<String>()
        var chain = SerialAsyncChain()
        var deliveries: [Task<Void, Never>] = []

        for index in 1...Self.deliveryCount {
            deliveries.append(
                chain.enqueue {
                    steps.append("start \(index)")
                    for _ in 0..<Self.yieldsInsideADelivery {
                        await Task.yield()
                    }
                    steps.append("end \(index)")
                })
        }
        for delivery in deliveries {
            await delivery.value
        }

        let expected = (1...Self.deliveryCount).flatMap { ["start \($0)", "end \($0)"] }
        #expect(steps.values == expected)
    }

    @Test("the returned task ends when its own delivery ends")
    func theReturnedTaskIsTheDelivery() async {
        let steps = Recorder<String>()
        var chain = SerialAsyncChain()

        let delivery = chain.enqueue { steps.append("delivered") }
        await delivery.value

        #expect(steps.values == ["delivered"])
    }
}

// MARK: - The queue metrics of the deliveries

/// Exercises the queue metrics of a chain with telemetry. Each delivery is one
/// task of the queue: the depth goes up at the enqueue and down at the end of
/// the delivery, and the end records one wait time, one run time and one
/// count with the outcome `succeeded`.
extension SerialAsyncChainTests {
    /// The recorder of the chain in each telemetry test.
    private static let telemetry = QueueTelemetry(name: .toolEvents)

    /// The dimensions of the depth meter of the chain.
    private static let queue = QueueMetricDimensions.queue(of: telemetry)

    /// The number of deliveries that wait behind the held delivery.
    private static let laterDeliveryCount = 2

    /// The number of deliveries of each telemetry test: the held delivery and
    /// the later deliveries.
    private static let allDeliveryCount = laterDeliveryCount + 1

    /// The depth after each enqueue, while the held delivery blocks the
    /// later deliveries: it goes up by 1 at each enqueue, to
    /// ``allDeliveryCount``.
    private static let depthWhileHeld = (1...allDeliveryCount).map(Double.init)

    /// The depth after the end of each delivery: it goes down by 1 at each
    /// end, back to 0.
    private static let depthAfterEachEnd = (0..<allDeliveryCount).reversed().map(Double.init)

    /// The depth after each change: up at each enqueue, then down at the end
    /// of each delivery, back to 0.
    private static let depthOfAllDeliveries = depthWhileHeld + depthAfterEachEnd

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

    /// The time that the held delivery runs on the manual clock of the
    /// chain. The held delivery moves that clock by this time.
    private static let heldRunTime = Duration.milliseconds(250)

    /// Enqueues one delivery that waits until the test releases it, and
    /// ``laterDeliveryCount`` deliveries behind it, on a chain whose
    /// telemetry reads a manual clock. The held delivery moves that clock by
    /// ``heldRunTime``. Then runs `whileHeld`, releases the held delivery,
    /// and waits until each delivery ends.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the chain records into.
    ///   - whileHeld: Runs while the held delivery blocks the later ones.
    /// - Throws: The error of `whileHeld`.
    private static func deliverBehindAHeldDelivery(
        into metrics: TestMetrics, whileHeld: () async throws -> Void
    ) async throws {
        let (mayEnd, release) = AsyncStream.makeStream(of: Void.self)
        let clock = ManualRunClock()
        var chain = SerialAsyncChain(telemetry: QueueTelemetry(name: telemetry.name, now: { clock.now }))
        let deliveries = withMetricsFactory(metrics) {
            let held = chain.enqueue {
                clock.advance(by: heldRunTime)
                for await _ in mayEnd {}
            }
            return [held] + (0..<laterDeliveryCount).map { _ in chain.enqueue {} }
        }
        try await whileHeld()
        release.finish()
        for delivery in deliveries {
            await delivery.value
        }
    }

    @Test("the depth counts each delivery that did not end, and goes back to 0")
    func theDepthCountsTheDeliveriesThatDidNotEnd() async throws {
        let metrics = TestMetrics()

        try await Self.deliverBehindAHeldDelivery(into: metrics) {
            let depthWhileHeld = try QueueMetricExpectations.depth(in: metrics, queue: Self.queue)
            #expect(depthWhileHeld == Self.depthWhileHeld)
        }

        #expect(try QueueMetricExpectations.depth(in: metrics, queue: Self.queue) == Self.depthOfAllDeliveries)
    }

    @Test("a later delivery records a wait time that covers the time that the held delivery runs")
    func aLaterDeliveryWaitsForTheHeldDelivery() async throws {
        let metrics = TestMetrics()

        // The later deliveries wait from their enqueue, before the held
        // delivery starts, until the held delivery ends. The held delivery
        // moves the manual clock of the chain by ``heldRunTime``, thus each
        // later wait time covers that time.
        try await Self.deliverBehindAHeldDelivery(into: metrics) {}

        let waitTimes = try QueueMetricExpectations.waitTimes(
            in: metrics, queue: Self.queue, outcome: QueueOutcome.succeeded.rawValue)
        // The deliveries end in the enqueue order, thus the first wait time is
        // the wait time of the held delivery.
        let laterWaitTimes = waitTimes.dropFirst()
        #expect(laterWaitTimes.count == Self.laterDeliveryCount)
        #expect(laterWaitTimes.allSatisfy { $0 >= Self.nanoseconds(of: Self.heldRunTime) })
    }

    @Test("each delivery records one count, one wait time and one run time with the outcome succeeded")
    func eachDeliveryRecordsOneCount() async throws {
        let metrics = TestMetrics()

        try await Self.deliverBehindAHeldDelivery(into: metrics) {}

        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: Self.queue, outcome: .succeeded, ran: true, count: Self.allDeliveryCount)
    }

    @Test("a chain made with no telemetry records no metric")
    func aChainWithNoTelemetryRecordsNothing() async {
        let metrics = TestMetrics()
        var chain = SerialAsyncChain()

        let delivery = withMetricsFactory(metrics) { chain.enqueue {} }
        await delivery.value

        #expect(metrics.meters.isEmpty)
        #expect(metrics.timers.isEmpty)
        #expect(metrics.counters.isEmpty)
    }
}
