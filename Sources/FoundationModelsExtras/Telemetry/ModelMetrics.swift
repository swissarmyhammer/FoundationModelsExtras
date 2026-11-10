import Metrics

/// The metric helpers that the model recorders share: the model-ref dimension
/// of a metric of one model, the duration timer of a model operation with its
/// outcome, and the run of an operation that records its outcome.
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

    /// Runs `body`, records its duration from `start` on the model timer
    /// `label` with its outcome, and gives the value or the error of `body`.
    ///
    /// The timer records ``ModelOperationOutcome/succeeded`` when `body`
    /// gives a value, and ``ModelOperationOutcome/failed`` when `body`
    /// throws. Thus a failed operation also records its duration.
    ///
    /// - Parameters:
    ///   - label: The name of the timer, from ``MetricName``.
    ///   - dimensions: The dimensions of the model of the operation, for
    ///     example from ``modelDimensions(of:)``.
    ///   - start: The instant that the operation started.
    ///   - body: The operation.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    nonisolated(nonsending) static func timeModelOperation<Output>(
        on label: String,
        dimensions: [(String, String)],
        since start: ContinuousClock.Instant,
        _ body: nonisolated(nonsending) () async throws -> Output
    ) async throws -> Output {
        try await recordingOutcome(of: body) { outcome in
            recordModelDuration(on: label, dimensions: dimensions, outcome: outcome, since: start)
        }
    }

    /// Runs `body`, gives its outcome to `record`, and gives the value or the
    /// error of `body`.
    ///
    /// `record` gets ``ModelOperationOutcome/succeeded`` when `body` gives a
    /// value, and ``ModelOperationOutcome/failed`` when `body` throws. It
    /// runs one time, after `body` and before the value or the error goes
    /// to the caller.
    ///
    /// - Parameters:
    ///   - body: The operation.
    ///   - record: Records the metrics of the operation with its outcome.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`.
    nonisolated(nonsending) static func recordingOutcome<Output>(
        of body: nonisolated(nonsending) () async throws -> Output,
        record: (ModelOperationOutcome) -> Void
    ) async throws -> Output {
        do {
            let output = try await body()
            record(.succeeded)
            return output
        } catch {
            record(.failed)
            throw error
        }
    }
}
