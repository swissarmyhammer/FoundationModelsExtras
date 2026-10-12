/// The counts of one embed call that its telemetry records: the token count,
/// the longest row, the sub-batch count, the rows over the token budget, and
/// the padding of each sub-batch.
///
/// The value comes from an ``EmbeddingBatchDivision`` only, thus a test needs
/// no model. The value holds counts only, never a token id or a text.
struct EmbeddingBatchStatistics: Equatable {
    /// The counts of one sub-batch: one padded tensor that the model runs on.
    struct SubBatch: Equatable {
        /// The number of rows of the sub-batch.
        let rows: Int

        /// The token count of the longest row of the sub-batch. The padding
        /// makes each row this long.
        let longestRow: Int

        /// The tokens of the padded tensor: (rows) x (longest row).
        let paddedTokens: Int

        /// The pad tokens divided by ``paddedTokens``: 0 when no row has pad
        /// tokens, and near 1 when the longest row pads many short rows. A
        /// sub-batch with no tokens has the ratio 0.
        let padRatio: Double
    }

    /// The number of texts of the call: one row for each text.
    let textCount: Int

    /// The sum of the token counts of the rows.
    let tokenCount: Int

    /// The token count of the longest row of the call, or 0 for no rows.
    let maxTokens: Int

    /// The number of sub-batches of the division.
    let subBatchCount: Int

    /// The number of rows that are longer than the token budget. Each of
    /// them is in a sub-batch by itself.
    let overBudgetRows: Int

    /// The counts of each sub-batch, in the order of
    /// ``EmbeddingBatchDivision/subBatches``.
    let subBatches: [SubBatch]

    /// Counts the rows and the sub-batches of `division`.
    ///
    /// - Parameter division: The division of the token rows of one call.
    init(of division: EmbeddingBatchDivision) {
        let lengths = division.subBatches.flatMap { $0.rows.map(\.count) }
        textCount = lengths.count
        tokenCount = lengths.reduce(0, +)
        maxTokens = lengths.max() ?? 0
        subBatchCount = division.subBatches.count
        overBudgetRows = lengths.filter { $0 > division.tokenBudget }.count
        subBatches = division.subBatches.map(SubBatch.init(of:))
    }
}

extension EmbeddingBatchStatistics.SubBatch {
    /// Counts the rows and the padding of `subBatch`.
    ///
    /// - Parameter subBatch: One sub-batch of a division.
    init(of subBatch: EmbeddingBatchDivision.SubBatch) {
        let lengths = subBatch.rows.map(\.count)
        let longestRow = lengths.max() ?? 0
        let paddedTokens = lengths.count * longestRow
        let padTokens = paddedTokens - lengths.reduce(0, +)
        self.init(
            rows: lengths.count, longestRow: longestRow, paddedTokens: paddedTokens,
            padRatio: paddedTokens == 0 ? 0 : Double(padTokens) / Double(paddedTokens))
    }
}
