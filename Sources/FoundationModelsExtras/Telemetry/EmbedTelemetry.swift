import Logging
import Metrics
import Tracing

/// The recorder of the telemetry of one embed call: the embed span, its
/// tokenize span and its sub-batch spans, the duration timer, the token
/// counter and the padded-tokens recorder.
///
/// ``traceEmbed(of:texts:tokenBudget:tokenize:vectors:)`` runs all the steps
/// of one call: it tokenizes the texts, divides the token rows into
/// sub-batches with ``EmbeddingBatchDivision``, runs the model on each
/// sub-batch, and puts the vectors back in the input order. The tokenizer and
/// the model are closures, thus a unit test can give a fake tokenizer and a
/// fake model, and no test needs an MLX model.
///
/// Each span goes through ``TracedCall``. Thus each span writes one "enter"
/// log record when it starts, and a call that hangs shows as an "enter"
/// record with no span that ends. The tokenize span and each sub-batch span
/// are children of the embed span, thus the tokenize time is separate from
/// the model time.
///
/// Each metric is made at call time, so that it uses the metrics factory of
/// the current task. A queue job of a pooled model restores the factory of its
/// submitter, thus the metrics of a call reach that factory.
///
/// The recorder records the model ref and counts only: the text count, the
/// token counts, the sub-batch counts and the padding. It never records a
/// text, a token id or a vector.
enum EmbedTelemetry {
    /// Runs one embed call in one embed span, and records its metrics.
    ///
    /// The embed span has the model ref and the counts of
    /// ``EmbeddingBatchStatistics``. The token counter gets the token count
    /// of the call when the tokenize step ends. The timer records the
    /// duration as the last step of the span, so the duration and the span
    /// measure the same interval.
    ///
    /// - Parameters:
    ///   - ref: The model of the call.
    ///   - texts: The texts of the call.
    ///   - tokenBudget: The most tokens, (rows) x (longest row), of one
    ///     sub-batch.
    ///   - tokenize: Gives the token row of one text.
    ///   - vectors: Runs the model on the token rows of one sub-batch, and
    ///     gives one vector for each row, in the order of the rows.
    /// - Returns: One vector for each text, in the order of `texts`.
    /// - Throws: The error of a traced call. The span gets the error status
    ///   and the type of the error, never its description.
    nonisolated(nonsending) static func traceEmbed<Vector>(
        of ref: ModelRef,
        texts: [String],
        tokenBudget: Int = EmbeddingBatchDivision.defaultTokenBudget,
        tokenize: (String) -> [Int],
        vectors: ([[Int]]) -> [Vector]
    ) async throws -> [Vector] {
        let start = ContinuousClock.now
        let logger = ExtrasTelemetry.makeLogger()
        return try await TracedCall.run(
            ExtrasTelemetry.SpanName.embed,
            logger: logger,
            attributes: { $0[ExtrasTelemetry.AttributeKey.modelRef] = ref.stringValue },
            metadata: [ExtrasTelemetry.LogMetadataKey.modelRef: .string(ref.stringValue)]
        ) { span in
            let division = try await TracedCall.run(ExtrasTelemetry.SpanName.embedTokenize, logger: logger) { _ in
                EmbeddingBatchDivision(rows: texts.map(tokenize), tokenBudget: tokenBudget)
            }
            let statistics = EmbeddingBatchStatistics(of: division)
            recordCall(statistics, of: ref, on: span)
            let output = division.inInputOrder(
                try await vectorsOfEachSubBatch(
                    of: division, statistics: statistics, ref: ref, logger: logger, vectors: vectors))
            Metrics.Timer(label: ExtrasTelemetry.MetricName.embedDuration, dimensions: dimensions(of: ref))
                .record(duration: ContinuousClock.now - start)
            return output
        }
    }

    /// Runs the model on each sub-batch of `division`, each in one sub-batch
    /// span, from the first sub-batch to the last.
    ///
    /// - Parameters:
    ///   - division: The division of the token rows of the call.
    ///   - statistics: The counts of `division`.
    ///   - ref: The model of the call.
    ///   - logger: The logger of the "enter" records.
    ///   - vectors: Runs the model on the token rows of one sub-batch.
    /// - Returns: The vectors of each sub-batch, in the order of
    ///   ``EmbeddingBatchDivision/subBatches``.
    /// - Throws: The error of a traced call.
    private nonisolated(nonsending) static func vectorsOfEachSubBatch<Vector>(
        of division: EmbeddingBatchDivision,
        statistics: EmbeddingBatchStatistics,
        ref: ModelRef,
        logger: Logger,
        vectors: ([[Int]]) -> [Vector]
    ) async throws -> [[Vector]] {
        // Each sub-batch span is an async traced call, and a `map` closure
        // cannot `await`. Thus a loop collects the vectors, one sub-batch at
        // a time, in order.
        var vectorsOfEachSubBatch: [[Vector]] = []
        for (subBatch, counts) in zip(division.subBatches, statistics.subBatches) {
            vectorsOfEachSubBatch.append(
                try await traceSubBatch(counts, of: ref, logger: logger) { vectors(subBatch.rows) })
        }
        return vectorsOfEachSubBatch
    }

    /// Runs the model on one sub-batch in one sub-batch span, and records
    /// the padded tokens of the sub-batch.
    ///
    /// - Parameters:
    ///   - counts: The counts of the sub-batch.
    ///   - ref: The model of the call.
    ///   - logger: The logger of the "enter" record.
    ///   - run: Runs the model on the token rows of the sub-batch.
    /// - Returns: The value of `run`.
    /// - Throws: The error of the traced call.
    private nonisolated(nonsending) static func traceSubBatch<Vector>(
        _ counts: EmbeddingBatchStatistics.SubBatch,
        of ref: ModelRef,
        logger: Logger,
        _ run: () -> [Vector]
    ) async throws -> [Vector] {
        try await TracedCall.run(
            ExtrasTelemetry.SpanName.embedSubBatch,
            logger: logger,
            attributes: { attributes in
                attributes[ExtrasTelemetry.AttributeKey.subBatchRows] = counts.rows
                attributes[ExtrasTelemetry.AttributeKey.subBatchLongestRow] = counts.longestRow
                attributes[ExtrasTelemetry.AttributeKey.subBatchPaddedTokens] = counts.paddedTokens
                attributes[ExtrasTelemetry.AttributeKey.subBatchPadRatio] = counts.padRatio
            }
        ) { _ in
            let output = run()
            Metrics.Recorder(label: ExtrasTelemetry.MetricName.embedSubBatchPaddedTokens, dimensions: dimensions(of: ref))
                .record(counts.paddedTokens)
            return output
        }
    }

    /// Gives `span` the counts of the call, and adds the token count of the
    /// call to the token counter of `ref`.
    ///
    /// - Parameters:
    ///   - statistics: The counts of the call.
    ///   - ref: The model of the call.
    ///   - span: The embed span of the call.
    private static func recordCall(_ statistics: EmbeddingBatchStatistics, of ref: ModelRef, on span: any Span) {
        span.updateAttributes { attributes in
            attributes[ExtrasTelemetry.AttributeKey.embedTextCount] = statistics.textCount
            attributes[ExtrasTelemetry.AttributeKey.embedTokenCount] = statistics.tokenCount
            attributes[ExtrasTelemetry.AttributeKey.embedMaxTokens] = statistics.maxTokens
            attributes[ExtrasTelemetry.AttributeKey.embedSubBatchCount] = statistics.subBatchCount
            attributes[ExtrasTelemetry.AttributeKey.embedOverBudgetRows] = statistics.overBudgetRows
        }
        Metrics.Counter(label: ExtrasTelemetry.MetricName.embedTokens, dimensions: dimensions(of: ref))
            .increment(by: statistics.tokenCount)
    }

    /// Gives the dimensions of an embed metric.
    ///
    /// - Parameter ref: The model of the call.
    /// - Returns: The model ref as its only dimension.
    private static func dimensions(of ref: ModelRef) -> [(String, String)] {
        [(ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue)]
    }
}
