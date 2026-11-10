import Metrics

/// The metric helpers that the model recorders share: the model-ref dimension
/// of a metric of one model, and the duration timer of a model operation with
/// its outcome.
///
/// Each recorder of one model, for example ``EmbedTelemetry``,
/// ``LogitsTelemetry``, ``ModelLoadTelemetry`` and ``PoolTelemetry``, makes its
/// dimensions and its duration timer with these helpers. Thus each model
/// metric has the same dimension keys in the same order.
///
/// Each metric is made at call time, so that it uses the metrics factory of
/// the current task.
extension ExtrasTelemetry {
    /// Gives the dimensions of a metric that belongs to one model.
    ///
    /// - Parameter ref: The model of the metric.
    /// - Returns: The model ref as the only dimension.
    static func modelDimensions(of ref: ModelRef) -> [(String, String)] {
        [(DimensionKey.modelRef, ref.stringValue)]
    }

    /// Records the time from `start` to now on the model timer `label`, with
    /// `dimensions` and then the ``DimensionKey/modelOutcome`` dimension of
    /// `outcome`.
    ///
    /// - Parameters:
    ///   - label: The name of the timer, from ``MetricName``.
    ///   - dimensions: The dimensions of the model of the operation, for
    ///     example from ``modelDimensions(of:)``.
    ///   - outcome: How the operation ended.
    ///   - start: The instant that the operation started.
    static func recordModelDuration(
        on label: String,
        dimensions: [(String, String)],
        outcome: ModelOperationOutcome,
        since start: ContinuousClock.Instant
    ) {
        Metrics.Timer(
            label: label,
            dimensions: dimensions + [(DimensionKey.modelOutcome, outcome.rawValue)]
        ).record(duration: ContinuousClock.now - start)
    }
}
