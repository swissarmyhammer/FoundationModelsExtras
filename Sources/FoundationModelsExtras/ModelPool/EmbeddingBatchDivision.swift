/// The token rows of one embed call, sorted by token count and divided into
/// sub-batches by a token budget.
///
/// One padded tensor has (rows) x (longest row) tokens, and the attention cost
/// of a row increases with the square of its length. When all the rows of a
/// call go in one tensor, one long row pads each short row to its length. Here
/// each sub-batch holds rows of similar length, thus a long row does not pad
/// the short rows of a different sub-batch.
///
/// The budget limits the size of one tensor. It does not cut a row: a row
/// longer than the budget goes in a sub-batch by itself, with all its tokens.
struct EmbeddingBatchDivision: Equatable {
    /// The most tokens, (rows) x (longest row), of one sub-batch.
    ///
    /// The value is 32 rows of 512 tokens. FoundationModelsCodeContext embeds
    /// 32 code chunks in each call, thus a call of chunks of 512 tokens or
    /// fewer runs as one tensor, and the GPU gets enough rows to stay busy.
    /// The attention mask and the attention scores of a sub-batch increase
    /// with (rows) x (longest row) x (longest row), thus this budget keeps the
    /// memory of a sub-batch of short and medium rows small. The callers of
    /// `embed(texts:)` do not set it.
    static let defaultTokenBudget = 16_384

    /// One sub-batch: rows that the model runs on as one padded tensor.
    struct SubBatch: Equatable {
        /// The input index of each row, from the shortest row to the longest.
        let indices: [Int]

        /// The tokens of each row, in the order of ``indices``.
        let rows: [[Int]]
    }

    /// The sub-batches, from the shortest rows to the longest. Each input row
    /// is in one sub-batch.
    let subBatches: [SubBatch]

    /// Sorts `rows` by token count and divides them into sub-batches. Rows of
    /// one token count keep their input order.
    ///
    /// - Parameters:
    ///   - rows: The token rows of the call, in input order.
    ///   - tokenBudget: The most tokens, (rows) x (longest row), of one
    ///     sub-batch. A row longer than it goes in a sub-batch by itself.
    init(rows: [[Int]], tokenBudget: Int = defaultTokenBudget) {
        let order = rows.indices.sorted { (rows[$0].count, $0) < (rows[$1].count, $1) }
        subBatches = Self.divided(order, lengths: rows.map(\.count), tokenBudget: tokenBudget).map { indices in
            SubBatch(indices: indices, rows: indices.map { rows[$0] })
        }
    }

    /// Puts the vectors of the sub-batches back in the input order of the rows.
    ///
    /// - Parameter vectorsOfEachSubBatch: The vectors of each sub-batch of
    ///   ``subBatches``, in the order of its rows.
    /// - Returns: One vector for each input row, in input order.
    func inInputOrder<Vector>(_ vectorsOfEachSubBatch: [[Vector]]) -> [Vector] {
        precondition(
            vectorsOfEachSubBatch.map(\.count) == subBatches.map(\.indices.count),
            "each sub-batch must give one vector for each of its rows")
        return zip(subBatches.flatMap(\.indices), vectorsOfEachSubBatch.joined())
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Divides the sorted row indices into groups. A row goes in the last
    /// group when the group, with the row, stays in the budget. Else the row
    /// starts a new group.
    ///
    /// - Parameters:
    ///   - order: The input indices of the rows, from the shortest row to the
    ///     longest. Thus each new row is the longest row of its group.
    ///   - lengths: The token count of each input row.
    ///   - tokenBudget: The most tokens, (rows) x (longest row), of one group.
    /// - Returns: The input indices of each group.
    private static func divided(_ order: [Int], lengths: [Int], tokenBudget: Int) -> [[Int]] {
        order.reduce(into: []) { groups, index in
            if let last = groups.indices.last, (groups[last].count + 1) * lengths[index] <= tokenBudget {
                groups[last].append(index)
            } else {
                groups.append([index])
            }
        }
    }
}
