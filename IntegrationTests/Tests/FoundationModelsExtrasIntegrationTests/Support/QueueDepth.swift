@testable import FoundationModelsExtras
import MetricsTestKit
import TelemetryTestSupport

/// The depth metric of a queue of a pool, as a `TelemetryCapture` holds it.
///
/// A queue records its depth in the step that accepts a job, in the metrics
/// factory of the task that submits the job. Thus a test that submits in a
/// capture can wait for a depth with `TelemetryCapture.Context.wait(until:)`:
/// when the depth shows a job, the job is in the queue. The wait reads no
/// clock and does no poll.
enum QueueDepth {
    /// The last depth of the admission queue of a pool in `context`, or `nil`
    /// when that queue recorded no depth there.
    ///
    /// - Parameter context: The capture of the test.
    /// - Returns: The depth after the last change.
    @Sendable
    static func admission(in context: TelemetryCapture.Context) -> Double? {
        last(in: context, queue: [(ExtrasTelemetry.DimensionKey.queueName, QueueName.admission.rawValue)])
    }

    /// The last depth of the queue of the model of `key` in `context`, or
    /// `nil` when that queue recorded no depth there.
    ///
    /// - Parameters:
    ///   - key: The model whose hold gives the queue.
    ///   - context: The capture of the test.
    /// - Returns: The depth after the last change.
    static func model(_ key: ModelPoolKey, in context: TelemetryCapture.Context) -> Double? {
        last(
            in: context,
            queue: [
                (ExtrasTelemetry.DimensionKey.queueName, QueueName.model.rawValue),
                (ExtrasTelemetry.DimensionKey.modelRef, key.ref.stringValue),
            ])
    }

    /// The last value of the depth meter with the dimensions `queue`.
    ///
    /// - Parameters:
    ///   - context: The capture of the test.
    ///   - queue: The dimensions of the queue.
    /// - Returns: The last value, or `nil` when the capture has no such meter.
    private static func last(in context: TelemetryCapture.Context, queue: [(String, String)]) -> Double? {
        (try? context.metricsFactory.expectMeter(ExtrasTelemetry.MetricName.queueDepth, queue))?.values.last
    }
}
