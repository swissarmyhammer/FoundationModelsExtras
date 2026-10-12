import Logging
import Metrics

/// The recorder of the cache telemetry of the model pool: the acquires, the
/// evictions, the joins of a running load, the footprint meters, and the log
/// record of a failed footprint measure.
///
/// Each metric is made at call time, so that it uses the metrics factory of
/// the current task. An admission job restores the factory of its submitter,
/// thus the metrics of a load or an eviction reach that factory.
///
/// The recorder records names, model refs, counts and sizes only. It never
/// records a file path, a prompt, the description of a container or the
/// description of an error.
enum PoolTelemetry {
    /// Records one acquire of `ref` with its cache result.
    ///
    /// - Parameters:
    ///   - ref: The model of the acquire.
    ///   - result: How the pool gave the hold.
    static func recordAcquire(of ref: ModelRef, result: PoolCacheResult) {
        Counter(
            label: ExtrasTelemetry.MetricName.poolAcquires,
            dimensions: modelDimensions(of: ref) + [(ExtrasTelemetry.DimensionKey.cacheResult, result.rawValue)]
        ).increment()
    }

    /// Records one eviction of `ref`: one count, and the idle time when the
    /// pool knows the instant of the last release.
    ///
    /// - Parameters:
    ///   - ref: The evicted model.
    ///   - idleTime: The time from the last release to the start of the
    ///     eviction, or `nil` when the pool has no release instant.
    static func recordEviction(of ref: ModelRef, idleTime: Duration?) {
        Counter(label: ExtrasTelemetry.MetricName.poolEvictions, dimensions: modelDimensions(of: ref)).increment()
        guard let idleTime else { return }
        Metrics.Timer(label: ExtrasTelemetry.MetricName.poolIdleToEvict, dimensions: modelDimensions(of: ref))
            .record(duration: idleTime)
    }

    /// Records one eviction job of `ref` that evicted nothing.
    ///
    /// - Parameters:
    ///   - ref: The model of the eviction job.
    ///   - reason: Why the job evicted nothing.
    static func recordSkippedEviction(of ref: ModelRef, reason: PoolEvictionSkipReason) {
        Counter(
            label: ExtrasTelemetry.MetricName.poolEvictions,
            dimensions: modelDimensions(of: ref) + [(ExtrasTelemetry.DimensionKey.evictionReason, reason.rawValue)]
        ).increment()
    }

    /// Records one caller that waits for a load that another caller started.
    static func recordLoadJoin() {
        Counter(label: ExtrasTelemetry.MetricName.poolLoadJoins).increment()
    }

    /// Sets the four meters of the pool to `gauges`.
    ///
    /// - Parameter gauges: The memory and the resident models of the pool now.
    static func recordGauges(_ gauges: PoolGauges) {
        Meter(label: ExtrasTelemetry.MetricName.poolResidentBytes).set(gauges.residentBytes)
        Meter(label: ExtrasTelemetry.MetricName.poolLoadingBytes).set(gauges.loadingBytes)
        Meter(label: ExtrasTelemetry.MetricName.poolEvictingBytes).set(gauges.evictingBytes)
        Meter(label: ExtrasTelemetry.MetricName.poolResidentModels).set(gauges.residentModelCount)
    }

    /// Writes one error record for a failed footprint measure of `ref`. The
    /// record holds the type of `error` and the model ref, never the
    /// description of `error`.
    ///
    /// - Parameters:
    ///   - error: The error of the measure.
    ///   - ref: The measured model.
    static func logMeasureFailure(_ error: any Error, of ref: ModelRef) {
        ExtrasTelemetry.makeLogger().error(
            "\(ExtrasTelemetry.PoolLogMessage.measureFailed)",
            metadata: [
                ExtrasTelemetry.LogMetadataKey.errorType: .string(ExtrasTelemetry.errorType(of: error)),
                ExtrasTelemetry.LogMetadataKey.modelRef: .string(ref.stringValue),
            ]
        )
    }

    /// Gives the dimensions of a pool metric of one model.
    ///
    /// - Parameter ref: The model.
    /// - Returns: The model ref as the first dimension.
    private static func modelDimensions(of ref: ModelRef) -> [(String, String)] {
        [(ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue)]
    }
}

/// The values of the four meters of the model pool at one instant.
struct PoolGauges: Sendable {
    /// The bytes of the resident models. A model whose evict call runs is
    /// resident, as in ``ModelPoolFootprint``.
    let residentBytes: Int64

    /// The bytes of the load that runs now, or 0.
    let loadingBytes: Int64

    /// The bytes of the models whose evict call runs now.
    let evictingBytes: Int64

    /// The number of resident models.
    let residentModelCount: Int
}
