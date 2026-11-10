import Metrics
import Tracing

/// The recorder of the telemetry of one `logProbabilities` call of a
/// ``PooledLogitsModel``: the logits span, the call counter and the duration
/// timer.
///
/// ``PooledLogitsModel`` calls ``traceLogProbabilities(of:candidates:prompts:body:)``
/// for each call, thus each backend of the `.llm` role gets the same
/// telemetry with no code of its own.
///
/// The span goes through ``TracedCall``. Thus the span writes one "enter" log
/// record when it starts, and a call that hangs shows as an "enter" record
/// with no span that ends.
///
/// Each metric is made at call time, so that it uses the metrics factory of
/// the current task.
///
/// The recorder records the model ref and counts only: the prompt count, the
/// candidate count and the token count. It never records a text or a token
/// ID.
enum LogitsTelemetry {
    /// Runs one `logProbabilities` call in one logits span, and records its
    /// metrics.
    ///
    /// The logits span has the model ref, the prompt count, the candidate
    /// count and the token count, which is the sum of the prompt lengths.
    /// The call counter increments before `body` runs, thus a call that
    /// throws also counts. The timer records the duration as the last step
    /// of the span, on the success path and on the error path, with the
    /// ``ModelOperationOutcome`` of the call.
    ///
    /// - Parameters:
    ///   - ref: The model of the call.
    ///   - candidates: The candidate token IDs of the call.
    ///   - prompts: The prompts of the call, each as token IDs.
    ///   - body: Runs the call, and gives one row for each prompt.
    /// - Returns: The rows of `body`.
    /// - Throws: The error of `body`. The span gets the error status and the
    ///   type of the error, never its description.
    nonisolated(nonsending) static func traceLogProbabilities(
        of ref: ModelRef,
        candidates: [Int],
        prompts: [[Int]],
        body: nonisolated(nonsending) () async throws -> [[Double]]
    ) async throws -> [[Double]] {
        let start = ContinuousClock.now
        let dimensions = ExtrasTelemetry.modelDimensions(of: ref)
        Metrics.Counter(label: ExtrasTelemetry.MetricName.logitsCalls, dimensions: dimensions).increment()
        return try await TracedCall.run(
            ExtrasTelemetry.SpanName.logits,
            logger: ExtrasTelemetry.makeLogger(),
            attributes: { attributes in
                attributes[ExtrasTelemetry.AttributeKey.modelRef] = ref.stringValue
                attributes[ExtrasTelemetry.AttributeKey.logitsPromptCount] = prompts.count
                attributes[ExtrasTelemetry.AttributeKey.logitsCandidateCount] = candidates.count
                attributes[ExtrasTelemetry.AttributeKey.logitsTokenCount] = prompts.reduce(0) { $0 + $1.count }
            },
            metadata: [ExtrasTelemetry.LogMetadataKey.modelRef: .string(ref.stringValue)]
        ) { _ in
            try await ExtrasTelemetry.timeModelOperation(
                on: ExtrasTelemetry.MetricName.logitsDuration, dimensions: dimensions, since: start, body)
        }
    }
}
