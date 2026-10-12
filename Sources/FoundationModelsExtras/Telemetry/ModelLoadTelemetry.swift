import Metrics
import Tracing

/// The recorder of the load telemetry of a model: the load span, the span of
/// each load phase, the load timer, the evict timer and the footprint
/// recorder.
///
/// The load span and each phase span go through ``TracedCall``. Thus each
/// span writes one "enter" log record when it starts, and a load that hangs
/// shows as an "enter" record with no span that ends. Each phase span is a
/// descendant of the load span, in the same trace. A phase span is not always
/// a direct child: the MLX model factory downloads the files before it loads
/// the weights, thus the download span is inside the weights span, and the
/// `preload()` of an LLM loads the weights, thus the weights span of an LLM
/// is inside the preload span.
///
/// Each metric is made at call time, so that it uses the metrics factory of
/// the current task. An admission job restores the factory of its submitter,
/// thus the metrics of a load reach that factory.
///
/// The recorder records names, model refs, revisions, roles, outcomes and
/// byte counts only. It never records a file path, a cache folder, a URL or
/// the description of an error.
enum ModelLoadTelemetry {
    /// Runs `load` in one load span of `key`, and records the duration of
    /// `load` with its outcome on the load timer.
    ///
    /// The span has the model ref, the revision and the role of `key`. The
    /// "enter" record has the model ref and the role. The timer records the
    /// duration as the last step of the span, so the duration and the span
    /// measure the same interval.
    ///
    /// - Parameters:
    ///   - key: The model that `load` loads.
    ///   - load: The call to the loader.
    /// - Returns: The value of `load`.
    /// - Throws: The error of `load`. The span gets the error status and the
    ///   type of the error, never its description.
    nonisolated(nonsending) static func traceLoad<Output>(
        of key: ModelPoolKey,
        _ load: nonisolated(nonsending) () async throws -> Output
    ) async throws -> Output {
        let start = ContinuousClock.now
        let role = ExtrasTelemetry.telemetryRole(of: key.role)
        return try await TracedCall.run(
            ExtrasTelemetry.SpanName.modelLoad,
            logger: ExtrasTelemetry.makeLogger(),
            attributes: { attributes in
                attributes[ExtrasTelemetry.AttributeKey.modelRef] = key.ref.stringValue
                attributes[ExtrasTelemetry.AttributeKey.modelRevision] = MLXModelLoader.revision(of: key)
                attributes[ExtrasTelemetry.AttributeKey.modelRole] = role
            },
            metadata: [
                ExtrasTelemetry.LogMetadataKey.modelRef: .string(key.ref.stringValue),
                ExtrasTelemetry.LogMetadataKey.modelRole: .string(role),
            ]
        ) { _ in
            do {
                let output = try await load()
                recordLoadDuration(of: key, outcome: .succeeded, since: start)
                return output
            } catch {
                recordLoadDuration(of: key, outcome: .failed, since: start)
                throw error
            }
        }
    }

    /// Runs `phase` in one span with the name `spanName`, as a child of the
    /// span of the caller.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span of the phase, from
    ///     ``ExtrasTelemetry/SpanName``.
    ///   - phase: The phase. It gets the open span, to set an attribute.
    /// - Returns: The value of `phase`.
    /// - Throws: The error of `phase`. The span gets the error status and the
    ///   type of the error, never its description.
    nonisolated(nonsending) static func tracePhase<Output>(
        _ spanName: String,
        _ phase: nonisolated(nonsending) (any Span) async throws -> Output
    ) async throws -> Output {
        try await TracedCall.run(spanName, logger: ExtrasTelemetry.makeLogger(), phase)
    }

    /// Records the bytes that the footprint measure of `key` gave.
    ///
    /// - Parameters:
    ///   - bytes: The measured bytes.
    ///   - key: The measured model.
    static func recordFootprint(_ bytes: Int64, of key: ModelPoolKey) {
        Metrics.Recorder(label: ExtrasTelemetry.MetricName.modelFootprintBytes, dimensions: modelDimensions(of: key))
            .record(bytes)
    }

    /// Runs `evict` and records its duration on the evict timer of `key`.
    ///
    /// The evict call of a ``PooledModelLoader`` does not throw, thus each
    /// eviction records the outcome ``ModelOperationOutcome/succeeded``.
    ///
    /// - Parameters:
    ///   - key: The model that `evict` evicts.
    ///   - evict: The evict call of the loader.
    nonisolated(nonsending) static func timeEviction(
        of key: ModelPoolKey,
        _ evict: nonisolated(nonsending) () async -> Void
    ) async {
        let start = ContinuousClock.now
        await evict()
        recordDuration(on: ExtrasTelemetry.MetricName.modelEvictDuration, of: key, outcome: .succeeded, since: start)
    }

    /// Records the duration of one load of `key` on the load timer.
    ///
    /// - Parameters:
    ///   - key: The loaded model.
    ///   - outcome: How the load ended.
    ///   - start: The instant that the load started.
    private static func recordLoadDuration(
        of key: ModelPoolKey, outcome: ModelOperationOutcome, since start: ContinuousClock.Instant
    ) {
        recordDuration(on: ExtrasTelemetry.MetricName.modelLoadDuration, of: key, outcome: outcome, since: start)
    }

    /// Records the time from `start` to now on the model timer `label` of
    /// `key`, with `outcome`.
    ///
    /// - Parameters:
    ///   - label: The name of the timer, from ``ExtrasTelemetry/MetricName``.
    ///   - key: The model of the operation.
    ///   - outcome: How the operation ended.
    ///   - start: The instant that the operation started.
    private static func recordDuration(
        on label: String, of key: ModelPoolKey, outcome: ModelOperationOutcome, since start: ContinuousClock.Instant
    ) {
        Metrics.Timer(
            label: label,
            dimensions: modelDimensions(of: key) + [(ExtrasTelemetry.DimensionKey.modelOutcome, outcome.rawValue)]
        ).record(duration: ContinuousClock.now - start)
    }

    /// Gives the dimensions of a model metric of one key.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The model ref, then the role.
    private static func modelDimensions(of key: ModelPoolKey) -> [(String, String)] {
        [
            (ExtrasTelemetry.DimensionKey.modelRef, key.ref.stringValue),
            (ExtrasTelemetry.DimensionKey.modelRole, ExtrasTelemetry.telemetryRole(of: key.role)),
        ]
    }
}
