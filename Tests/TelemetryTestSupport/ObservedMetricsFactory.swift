import Metrics
import MetricsTestKit

/// A metrics factory that keeps each metric in a `TestMetrics` factory, and
/// tells a capture about each metric that it makes and each value that a
/// metric records.
///
/// `TestMetrics` is a final class with no hook, thus this factory stands in
/// front of it. It makes each metric in `TestMetrics`, so that the reads of
/// `TestMetrics` by label find the metric. It gives the code a handler that
/// writes each value to the `TestMetrics` handler, and then calls
/// ``metricDidChange``.
///
/// The handler of a metric is the front handler, not the `TestMetrics`
/// handler. Thus read a metric of this factory from `TestMetrics` by its
/// label, for example `expectCounter(label)`, and not by the metric value.
final class ObservedMetricsFactory: MetricsFactory {
    /// The factory that keeps each metric.
    let metrics: TestMetrics

    /// Called after each metric that this factory makes, and after each value
    /// that one of its metrics records.
    let metricDidChange: @Sendable () -> Void

    /// Makes a factory in front of `metrics`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that keeps each metric.
    ///   - metricDidChange: Called after each change of a metric.
    init(metrics: TestMetrics, metricDidChange: @escaping @Sendable () -> Void) {
        self.metrics = metrics
        self.metricDidChange = metricDidChange
    }

    /// Makes a counter in ``metrics``.
    ///
    /// - Parameters:
    ///   - label: The label of the counter.
    ///   - dimensions: The dimensions of the counter.
    /// - Returns: A front handler of the counter.
    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        observed(metrics.makeCounter(label: label, dimensions: dimensions))
    }

    /// Makes a meter in ``metrics``.
    ///
    /// - Parameters:
    ///   - label: The label of the meter.
    ///   - dimensions: The dimensions of the meter.
    /// - Returns: A front handler of the meter.
    func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        observed(metrics.makeMeter(label: label, dimensions: dimensions))
    }

    /// Makes a recorder in ``metrics``.
    ///
    /// - Parameters:
    ///   - label: The label of the recorder.
    ///   - dimensions: The dimensions of the recorder.
    ///   - aggregate: Whether the recorder aggregates its values.
    /// - Returns: A front handler of the recorder.
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        observed(metrics.makeRecorder(label: label, dimensions: dimensions, aggregate: aggregate))
    }

    /// Makes a timer in ``metrics``.
    ///
    /// - Parameters:
    ///   - label: The label of the timer.
    ///   - dimensions: The dimensions of the timer.
    /// - Returns: A front handler of the timer.
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        observed(metrics.makeTimer(label: label, dimensions: dimensions))
    }

    /// Removes a counter from ``metrics``.
    ///
    /// - Parameter handler: A handler that this factory made.
    func destroyCounter(_ handler: CounterHandler) {
        metrics.destroyCounter(Self.target(of: handler))
    }

    /// Removes a meter from ``metrics``.
    ///
    /// - Parameter handler: A handler that this factory made.
    func destroyMeter(_ handler: MeterHandler) {
        metrics.destroyMeter(Self.target(of: handler))
    }

    /// Removes a recorder from ``metrics``.
    ///
    /// - Parameter handler: A handler that this factory made.
    func destroyRecorder(_ handler: RecorderHandler) {
        metrics.destroyRecorder(Self.target(of: handler))
    }

    /// Removes a timer from ``metrics``.
    ///
    /// - Parameter handler: A handler that this factory made.
    func destroyTimer(_ handler: TimerHandler) {
        metrics.destroyTimer(Self.target(of: handler))
    }

    /// Puts a front handler before `target`, and tells the capture that a
    /// metric was made.
    ///
    /// - Parameter target: The handler that `TestMetrics` made.
    /// - Returns: The front handler.
    private func observed<Target: Sendable>(_ target: Target) -> ObservedMetricHandler<Target> {
        let handler = ObservedMetricHandler(target: target, metricDidChange: metricDidChange)
        metricDidChange()
        return handler
    }

    /// The `TestMetrics` handler behind a front handler.
    ///
    /// - Parameter handler: A handler that this factory made, or a different
    ///   handler.
    /// - Returns: The target of a front handler, or else `handler` itself.
    private static func target<Handler: Sendable>(of handler: Handler) -> Handler {
        (handler as? ObservedMetricHandler<Handler>)?.target ?? handler
    }
}

/// A handler that writes each value to the handler of a `TestMetrics`
/// factory, and then tells the capture about the change.
///
/// The handler conforms to the handler protocol of its target: a counter, a
/// meter, a recorder or a timer.
final class ObservedMetricHandler<Target: Sendable>: Sendable {
    /// The handler that keeps the values.
    let target: Target

    /// Called after each value that this handler records.
    let metricDidChange: @Sendable () -> Void

    /// Makes a handler in front of `target`.
    ///
    /// - Parameters:
    ///   - target: The handler that keeps the values.
    ///   - metricDidChange: Called after each value.
    init(target: Target, metricDidChange: @escaping @Sendable () -> Void) {
        self.target = target
        self.metricDidChange = metricDidChange
    }

    /// Gives one change to the target, then tells the capture about it.
    ///
    /// - Parameter change: The change of the target.
    func apply(_ change: (Target) -> Void) {
        change(target)
        metricDidChange()
    }
}

// Each handler protocol of swift-metrics inherits this protocol. Each
// conditional conformance below needs the conformance for each target, thus
// the handler declares it here with no condition.
extension ObservedMetricHandler: _SwiftMetricsSendableProtocol {}

extension ObservedMetricHandler: CounterHandler where Target == any CounterHandler {
    /// Adds `amount` to the counter.
    ///
    /// - Parameter amount: The amount to add.
    func increment(by amount: Int64) {
        apply { $0.increment(by: amount) }
    }

    /// Sets the counter to zero.
    func reset() {
        apply { $0.reset() }
    }
}

extension ObservedMetricHandler: MeterHandler where Target == any MeterHandler {
    /// Sets the meter to `value`.
    ///
    /// - Parameter value: The new value.
    func set(_ value: Int64) {
        apply { $0.set(value) }
    }

    /// Sets the meter to `value`.
    ///
    /// - Parameter value: The new value.
    func set(_ value: Double) {
        apply { $0.set(value) }
    }

    /// Adds `amount` to the meter.
    ///
    /// - Parameter amount: The amount to add.
    func increment(by amount: Double) {
        apply { $0.increment(by: amount) }
    }

    /// Removes `amount` from the meter.
    ///
    /// - Parameter amount: The amount to remove.
    func decrement(by amount: Double) {
        apply { $0.decrement(by: amount) }
    }
}

extension ObservedMetricHandler: RecorderHandler where Target == any RecorderHandler {
    /// Records `value`.
    ///
    /// - Parameter value: The value.
    func record(_ value: Int64) {
        apply { $0.record(value) }
    }

    /// Records `value`.
    ///
    /// - Parameter value: The value.
    func record(_ value: Double) {
        apply { $0.record(value) }
    }
}

extension ObservedMetricHandler: TimerHandler where Target == any TimerHandler {
    /// Records one duration.
    ///
    /// - Parameter duration: The duration, in nanoseconds.
    func recordNanoseconds(_ duration: Int64) {
        apply { $0.recordNanoseconds(duration) }
    }

    /// Gives the display unit to the timer. The display unit is not a value,
    /// thus the capture gets no change.
    ///
    /// - Parameter unit: The display unit.
    func preferDisplayUnit(_ unit: TimeUnit) {
        target.preferDisplayUnit(unit)
    }
}
